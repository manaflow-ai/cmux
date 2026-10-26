import CmuxNextAgentActivity
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Each stream of the Agent Activity, Cloud, Keyboard Shortcuts, icon picker, file and Passwords
/// providers names what ``PageRouter`` keeps of it while the page is hidden or frozen
/// (p13-webui-026). A stream whose event is the whole state, or an empty "re-read" signal, keeps
/// the newest (`.latest`). A stream whose events the page applies one by one with no re-read on a
/// gap (Cloud's machine deltas, the file page's look deltas, the icon picker's first event with the
/// catalog, Passwords' per-profile re-read signals) never drops (`.ordered`).
@MainActor @Suite struct PageProviderFrozenDeliveryBatchCTests {
    @Test func agentActivityStateKeepsTheNewest() async throws {
        let source = AgentActivityMockSource()
        let page = AgentActivityPageProvider(requests: AgentActivityRequests(model: AgentActivityModel(source: source), source: source))
        let state = try await Self.subscribe(page, AgentActivityPageProvider.stateStream)
        defer { state.cancel() }
        #expect(state.frozenDelivery == .latest, "each state event carries the whole state")
    }

    @Test func cloudMachineWatchNeverDrops() async throws {
        let page = CloudPageProvider(op: { _, _, _, _ in .object(["revision": .number(1)]) })
        let watch = try await Self.subscribe(page, CloudPageProvider.watchStream)
        defer { watch.cancel() }
        #expect(watch.frozenDelivery == .ordered, "a dropped upsert or removal would leave the page's list wrong")
    }

    @Test func keybindingsStreamsKeepTheNewest() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = KeybindingsPageProvider(services: services)
        for stream in ["cmux.keybindings.recorded", "cmux.keybindings.changed"] {
            let subscription = try await Self.subscribe(page, stream)
            defer { subscription.cancel() }
            #expect(subscription.frozenDelivery == .latest, "\(stream): the newest event says it all")
        }
        withExtendedLifetime(services) {} // the provider holds its services unowned
    }

    @Test func iconPickerSessionNeverDrops() async throws {
        let page = IconPickerProvider(prefs: IconPickerPrefsStore(services: nil))
        let session = try await Self.subscribe(page, IconPickerProvider.sessionStream)
        defer { session.cancel() }
        #expect(session.frozenDelivery == .ordered, "only the first event carries the symbol catalog")
    }

    @Test func fileChangesKeepTheNewestAndLookNeverDrops() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for kind in [FilePageKind.markdown, .editor] {
            let url = folder.appending(path: kind == .markdown ? "a.md" : "a.txt")
            try Data("# A\n".utf8).write(to: url)
            let page = FilePageProvider(kind: kind, file: url, host: FileHost(), libraries: nil, images: NoImages())
            defer { page.close() }
            let changes = try await Self.subscribe(page, kind.op("changes"))
            defer { changes.cancel() }
            #expect(changes.frozenDelivery == .latest, "\(kind): each change carries the whole file")
            let look = try await Self.subscribe(page, kind.op("look"))
            defer { look.cancel() }
            #expect(look.frozenDelivery == .ordered, "\(kind): each look event names only the keys that changed")
        }
    }

    @Test func passwordsChangedNeverDrops() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "cn-frozen-delivery-\(UUID().uuidString).csv")
        let person = PasswordExportOffTests.Approver(destination: destination)
        let page = PasswordsPageProvider(store: SamplePasswordStore(), profiles: { [.init(id: "default", name: "Default")] },
                                         confirmations: person, authenticator: person, secrets: person)
        let changed = try await Self.subscribe(page, PasswordOps.changed)
        defer { changed.cancel() }
        #expect(changed.frozenDelivery == .ordered, "a later event for another profile does not stand for a dropped one")
    }

    private static func subscribe(_ page: any PageProvider, _ stream: String) async throws -> PageSubscription {
        try await page.subscribe(stream, filter: [:], context: PageCallContext(page: "cmux.test"), onEvent: { _ in })
    }

    private final class FileHost: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> CmuxNextSettings.JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> CmuxNextSettings.JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: CmuxNextSettings.JSONValue, by writer: SettingWriter) async throws {}
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
