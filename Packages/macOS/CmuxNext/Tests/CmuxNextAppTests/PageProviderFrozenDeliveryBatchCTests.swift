import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextApp
import CmuxNextWakeups

private typealias PageJSON = CmuxNextSettings.JSONValue

/// The `.ordered` streams of p13-webui-026, each through a real ``PageRouter`` hold: the page is
/// hidden (``PageRouter/holdDelivery()``), the real provider sends, and on release the page gets
/// every event in order with no `gap` and no ``PageProvider/eventDeliveryDropped(stream:data:publicationID:)``.
/// Each test is one reason a stream may not keep only its newest event: the icon picker's first
/// event carries the symbol catalog, Cloud's machine deltas, the file page's look deltas, and
/// Passwords' per-profile re-read signals.
@MainActor @Suite struct PageProviderFrozenDeliveryBatchCTests {
    /// The warm picker page subscribes while hidden; its first event (the only one with the
    /// catalog) is held, and a picker opened before the page shows must not replace it.
    @Test func iconPickerCatalogEventSurvivesASessionBegunWhileHidden() async throws {
        let catalog = IconPickerSymbolCatalog(names: ["star"], keywords: ["favorite"], categories: [])
        let provider = IconPickerProvider(prefs: IconPickerPrefsStore(services: nil), catalog: catalog)
        let page = HeldPage(namespace: "cmux.iconPicker.", provider: provider)
        page.router.holdDelivery()
        try await page.subscribe(IconPickerProvider.sessionStream)
        await page.settle(held: 1) // the subscribe's first event, flushed after the reply
        provider.begin(IconPickerSession(id: "s1", current: nil)) { _ in }
        #expect(page.router.heldEventCount == 2)
        #expect(page.sent.isEmpty, "nothing reaches a hidden page")

        page.router.releaseDelivery()
        let events = page.events
        #expect(events.count == 2)
        #expect(events.first?["data"]?["symbols"]?.arrayValue?.compactMap(\.stringValue) == ["star"], "the first event keeps the catalog")
        #expect(events.first?["data"]?["id"]?.stringValue == "")
        #expect(events.last?["data"]?["id"]?.stringValue == "s1")
        #expect(events.last?["data"]?["symbols"] == nil, "a later session carries no catalog")
        #expect(events.allSatisfy { $0["gap"] == nil })
        #expect(page.recorder.dropped.isEmpty)
    }

    /// Two machine upserts while the Cloud page is hidden: the page applies each, with no re-read
    /// on a gap, so both arrive in order.
    @Test func cloudUpsertsWhileHiddenAllArriveInOrder() async throws {
        let provider = CloudPageProvider(op: { op, _, _, _ in Self.cloudAnswer(op) })
        let page = HeldPage(namespace: CloudPageProvider.prefix, provider: provider)
        try await page.subscribe(CloudPageProvider.watchStream)
        page.router.holdDelivery()
        let context = PageCallContext(page: "cmux.test")
        _ = try await provider.call("cmux.cloud.machine.start", params: ["machine": "m1"], context: context)
        _ = try await provider.call("cmux.cloud.machine.stop", params: ["machine": "m2"], context: context)
        #expect(page.sent.isEmpty, "nothing reaches a hidden page")

        page.router.releaseDelivery()
        let events = page.events
        #expect(events.map { $0["data"]?["type"]?.stringValue } == ["upsert", "upsert"])
        #expect(events.map { $0["data"]?["machine"]?["id"]?.stringValue } == ["m1", "m2"])
        #expect(events.map { $0["seq"]?.doubleValue } == [1, 2])
        #expect(events.allSatisfy { $0["gap"] == nil })
        #expect(page.recorder.dropped.isEmpty)
    }

    /// Look deltas while a markdown or editor tab is hidden (a settings change, then a theme.css
    /// save): each names only its own keys, so both arrive.
    @Test func fileLookDeltasWhileHiddenAllArriveInOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for kind in [FilePageKind.markdown, .editor] {
            let url = folder.appending(path: kind == .markdown ? "a.md" : "a.txt")
            try Data("# A\n".utf8).write(to: url)
            let host = FileHost()
            let provider = FilePageProvider(kind: kind, file: url, host: host, libraries: nil, images: NoImages(), deadlines: .testing())
            defer { provider.close() }
            let page = HeldPage(namespace: kind.namespace + ".", provider: provider)
            try await page.subscribe(kind.op("look"))
            page.router.holdDelivery()
            host.sendLook(["fontSize": 15])
            host.sendLook(["themeCSS": "body { color: red; }"])

            page.router.releaseDelivery()
            let events = page.events
            #expect(events.map { $0["data"]?["fontSize"]?.doubleValue } == [15, nil], "\(kind)")
            #expect(events.map { $0["data"]?["themeCSS"]?.stringValue } == [nil, "body { color: red; }"], "\(kind)")
            #expect(events.allSatisfy { $0["gap"] == nil }, "\(kind)")
            #expect(page.recorder.dropped.isEmpty, "\(kind)")
        }
    }

    /// Changes to two profiles while the Passwords page is hidden: the page re-reads only the
    /// profile it shows, so the later event for `work` does not stand for the one for `default`.
    @Test func passwordsChangesForTwoProfilesWhileHiddenBothArrive() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString).csv")
        let person = PasswordExportOffTests.Approver(destination: destination)
        let store = SamplePasswordStore()
        store.savedExceptions["work"] = store.savedExceptions["default"]
        let provider = PasswordsPageProvider(store: store, profiles: { [.init(id: "default", name: "Default")] },
                                             confirmations: person, authenticator: person, secrets: person,
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let page = HeldPage(namespace: "cmux.passwords.", provider: provider)
        try await page.subscribe(PasswordOps.changed)
        page.router.holdDelivery()
        #expect(try await store.removeException("e1", profile: "default"))
        #expect(try await store.removeException("e1", profile: "work"))

        page.router.releaseDelivery()
        let events = page.events
        #expect(events.map { $0["data"]?["profile"]?.stringValue } == ["default", "work"])
        #expect(events.allSatisfy { $0["gap"] == nil })
        #expect(page.recorder.dropped.isEmpty)
    }

    /// The Cloud app server's answer to each machine op: the machine it names, at a new revision.
    private nonisolated static func cloudAnswer(_ op: String) -> CmuxNextDaemon.JSONValue {
        switch op {
        case "cloud.machine.start": .object(["machine": .object(["id": .string("m1")]), "revision": .number(2)])
        case "cloud.machine.stop": .object(["machine": .object(["id": .string("m2")]), "revision": .number(3)])
        default: .object(["revision": .number(1)])
        }
    }

    /// A page whose router serves one provider's namespace and records every envelope sent.
    private final class HeldPage {
        let router: PageRouter
        let recorder: DropRecorder
        private(set) var sent: [PageJSON] = []

        init(namespace: String, provider: any PageProvider) {
            recorder = DropRecorder(provider)
            router = PageRouter(descriptor: PageDescriptor(id: "cmux.test", resource: "test", processGroup: .solo,
                                                           namespaces: [namespace]),
                                routes: [PageRoute(prefix: namespace, provider: recorder)])
            router.send = { [weak self] envelope in self?.sent.append(envelope) }
        }

        /// Every event that reached the page, a release batch (`evs`) unpacked in its order.
        var events: [PageJSON] {
            sent.flatMap { envelope -> [PageJSON] in
                switch envelope["t"]?.stringValue {
                case "ev": [envelope]
                case "evs": envelope["events"]?.arrayValue ?? []
                default: []
                }
            }
        }

        func subscribe(_ stream: String) async throws {
            let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(stream)])
            try #require(reply["t"]?.stringValue == "ok", "\(stream): \(reply)")
        }

        /// Lets the router's post-reply flush run until the hold keeps `count` events.
        func settle(held count: Int) async {
            for _ in 0..<200 where router.heldEventCount < count { await Task.yield() }
            #expect(router.heldEventCount == count)
        }
    }

    /// Passes everything to the real provider and records each event the router reports dropped.
    private final class DropRecorder: PageProvider {
        let inner: any PageProvider
        private(set) var dropped: [PageJSON] = []

        init(_ inner: any PageProvider) { self.inner = inner }

        var eventsAfterSubscribeReply: Bool { inner.eventsAfterSubscribeReply }
        var eventDeliveryID: UInt64? { inner.eventDeliveryID }

        func call(_ op: String, params: PageJSON, context: PageCallContext) async throws -> PageJSON {
            try await inner.call(op, params: params, context: context)
        }

        func subscribe(_ stream: String, filter: PageJSON, context: PageCallContext,
                       onEvent: @escaping @MainActor (PageJSON) -> Void) async throws -> PageSubscription {
            try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
        }

        func eventDeliveryDropped(stream: String, data: PageJSON, publicationID: UInt64?) {
            dropped.append(data)
        }
    }

    private final class FileHost: FilePageHosting {
        private var lookListener: (@MainActor (PageJSON) -> Void)?

        /// One look delta, as ``FilePageLook`` publishes it.
        func sendLook(_ changed: PageJSON) { lookListener?(changed) }

        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> PageJSON { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> PageJSON { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (PageJSON) -> Void) -> () -> Void {
            lookListener = onLook
            return { [weak self] in self?.lookListener = nil }
        }
        func setPreference(key: String, value: PageJSON, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }
}
