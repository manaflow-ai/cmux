@testable import CmuxNextApp
@testable import CmuxNextDiff
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The freeze rule each real page stream declares (``PageStreamFreezing``), checked against the
/// events it really sends: while a hidden cmux page is frozen, a push of the host's state or
/// changes thaws nothing, and the page gets one event per key at the thaw that leaves it where the
/// events one by one would (perf-lead.md F3). Before, the daemon relay, the file and diff streams,
/// Cloud's machine watch and `settings.changed` said each event counts, so each push thawed the
/// hidden page and restarted its grace: History, an open file an agent rewrites, Settings and Cloud
/// never stayed frozen while anything happened.
@MainActor
struct CmuxPageStreamFreezingTests {
    /// The events a frozen page's stream with `freezing` holds after `events`, and how many times
    /// they thawed the page.
    private func freeze(_ freezing: PageStreamFreezing, _ events: [JSONValue]) -> (wakes: Int, held: [JSONValue]) {
        let delivery = PageFrozenDelivery()
        var wakes = 0
        delivery.freeze { wakes += 1 }
        for event in events { _ = delivery.hold(sub: 1, event, publicationID: nil, freezing: freezing) }
        return (wakes, delivery.thaw().map(\.data))
    }

    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
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

    /// History hears `history-changed` from the daemon (page-router.json): a notice the page answers
    /// by reading its list again. Browsing while History is hidden sends one per navigation.
    @Test func historyChangedWhileFrozenThawsNothingAndGoesOnceAtTheThaw() {
        let events = (0..<100).map { index -> JSONValue in ["visit": .number(Double(index))] }
        let (wakes, held) = freeze(DaemonPageRelay.freezing(ofEvent: "history-changed"), events)
        #expect(wakes == 0, "a history-changed push thawed the hidden History page")
        #expect(held == [["visit": 99]])
    }

    /// A daemon event this app declares no rule for folds into the relay's gap notice, which every
    /// relay listener answers by reading again.
    @Test func anUndeclaredDaemonEventFoldsIntoOneResync() {
        let (wakes, held) = freeze(DaemonPageRelay.freezing(ofEvent: "future-changed"), [["a": 1], ["b": 2]])
        #expect(wakes == 0)
        #expect(held == [["resync": true]])
    }

    /// A file page's `changes`: each event is the file's whole state on disk, so a file an agent
    /// rewrites keeps exactly the last one while the page is frozen.
    @Test func aFilesChangesWhileFrozenKeepOnlyTheLastAndThawNothing() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "stream-freezing-\(UUID().uuidString).md")
        let provider = FilePageProvider(kind: .markdown, file: url, host: Host(), libraries: nil, images: NoImages())
        defer { provider.close() }
        let context = PageCallContext(page: FilePageKind.markdown.namespace)
        let changes = try await provider.subscribe(FilePageKind.markdown.op("changes"), filter: .object([:]), context: context) { _ in }
        let look = try await provider.subscribe(FilePageKind.markdown.op("look"), filter: .object([:]), context: context) { _ in }
        defer { changes.cancel(); look.cancel() }

        let writes = (0..<50).map { index -> JSONValue in
            ["path": .string(url.path), "hash": .string("h\(index)"), "text": .string("text \(index)")]
        }
        let deleted: JSONValue = ["path": .string(url.path), "hash": .null, "deleted": true]
        let (wakes, held) = freeze(changes.freezing, writes + [deleted])
        #expect(wakes == 0, "a disk change thawed the hidden file page")
        #expect(held == [deleted])

        // The look: only the members that changed, each whole.
        let (lookWakes, lookHeld) = freeze(look.freezing, [["themeCSS": "a"], ["settings": ["zoom": 1]], ["themeCSS": "b"]])
        #expect(lookWakes == 0, "a look push thawed the hidden file page")
        #expect(lookHeld == [["themeCSS": "b", "settings": ["zoom": 1]]])
    }

    /// `settings.changed` names the keys one load changed: the held event names every key changed
    /// while the page was frozen, with the newest revision.
    @Test func settingsChangedFoldsTheKeysAndKeepsTheNewestRevision() {
        let (wakes, held) = freeze(SettingsPageProvider.changedFreezing, [
            ["revision": 2, "keys": ["a", "b"]],
            ["revision": 3, "keys": ["b", "c"]],
            ["revision": 4, "keys": ["a"]],
        ])
        #expect(wakes == 0, "a settings change thawed the hidden Settings page")
        #expect(held == [["revision": 4, "keys": ["a", "b", "c"]]])
    }

    /// Cloud's machine watch: the newest event of each machine, in the order they came.
    @Test func cloudMachineEventsKeepTheNewestOfEachMachine() {
        let (wakes, held) = freeze(CloudPageProvider.watchFreezing, [
            ["type": "upsert", "revision": 1, "machine": ["id": "m1", "state": "starting"]],
            ["type": "upsert", "revision": 2, "machine": ["id": "m2", "state": "starting"]],
            ["type": "upsert", "revision": 3, "machine": ["id": "m1", "state": "running"]],
            ["type": "removed", "revision": 4, "id": "m2"],
        ])
        #expect(wakes == 0, "a machine change thawed the hidden Cloud page")
        #expect(held == [
            ["type": "upsert", "revision": 3, "machine": ["id": "m1", "state": "running"]],
            ["type": "removed", "revision": 4, "id": "m2"],
        ])
    }

    /// A diff's sidecar events: the newest of each kind per session.
    @Test func diffEventsKeepTheNewestOfEachKindPerSession() {
        let (wakes, held) = freeze(DiffPageProvider.eventsFreezing, [
            ["type": "sessionStatus", "sessionId": "s", "status": "opening"],
            ["type": "patchReady", "sessionId": "s", "patch": ["id": "p1"]],
            ["type": "sessionStatus", "sessionId": "s", "status": "ready"],
            ["type": "patchReady", "sessionId": "s", "patch": ["id": "p2"]],
        ])
        #expect(wakes == 0, "a diff event thawed the hidden diff page")
        #expect(held == [
            ["type": "sessionStatus", "sessionId": "s", "status": "ready"],
            ["type": "patchReady", "sessionId": "s", "patch": ["id": "p2"]],
        ])
    }
}
