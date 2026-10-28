@testable import CmuxNextDiff
import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

private typealias PageJSON = CmuxNextSettings.JSONValue

/// The diff tab's prefs stream through a real ``PageRouter`` hold. Each event is
/// the whole prefs, so while the page is hidden or frozen the router keeps only the newest
/// (`.latest`): at release the page gets that one, with no gap, and each older one is reported
/// dropped once. The languages stream sends the whole pack and names the same policy
/// (``DiffPageProvider/snapshotFrozenDelivery``); its feed reads the file system, so the router's
/// own newest-wins behavior is PageRouterFrozenDeliveryTests'.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiffPageProviderFrozenDeliveryTests {
    /// Prefs a test changes by hand.
    private final class Prefs: DiffPrefsStoring {
        private var listener: (@MainActor ([String: PageJSON]) -> Void)?

        /// One change of the stored prefs, as the settings store reports it.
        func send(_ prefs: [String: PageJSON]) { listener?(prefs) }

        func prefs() -> [String: PageJSON] { [:] }
        func setPref(_ key: String, to value: PageJSON) async throws {}
        func listen(_ onPrefs: @escaping @MainActor ([String: PageJSON]) -> Void) -> () -> Void {
            listener = onPrefs
            return { [weak self] in self?.listener = nil }
        }
    }

    @Test func prefsChangedWhileHiddenKeepOnlyTheNewest() async throws {
        let viewed = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffFrozenDelivery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: viewed) }
        let prefs = Prefs()
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil,
                                        stores: DiffPageStores(prefs: prefs, viewed: DiffViewedFiles(url: viewed, runner: BackgroundWork(label: "test.diff-viewed"))))
        let page = PageHoldHarness(descriptor: .diff, prefix: "cmux.diff.", provider: provider)
        let reply = await page.subscribe(DiffPageProvider.prefsStream)
        try #require(reply["t"]?.stringValue == "ok", "\(reply)")
        // One change while shown: once it arrives, the router's post-reply flush has run.
        prefs.send(["wrap": .bool(true)])
        await page.waitForEvents(1)

        page.router.holdDelivery()
        prefs.send(["wrap": .bool(false)])
        prefs.send(["wrap": .bool(false), "tabSize": .number(4)])
        prefs.send(["wrap": .bool(true), "tabSize": .number(8)])
        #expect(page.events.count == 1, "nothing reaches a hidden page")
        #expect(page.router.heldEventCount == 1)

        page.router.releaseDelivery()
        let events = page.events
        #expect(events.count == 2)
        #expect(events.last?["data"]?["prefs"] == PageJSON.object(["wrap": .bool(true), "tabSize": .number(8)]))
        #expect(events.map { $0["seq"]?.doubleValue } == [1, 2])
        #expect(events.allSatisfy { $0["gap"] == nil }, "a whole-value stream needs no resync")
        #expect(page.dropped.map { $0["prefs"]?["tabSize"]?.doubleValue } == [nil, 4], "each older event is reported once")
    }
}
