@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextSettings
import Testing

/// Task 224 of plans/cmux-next/chrome-parity/p01-process.md: in host mode a Chromium page is a hosted
/// context in its pane, with no page window. The world invariants count such pages (`hostPageTabs`): the
/// page view in the pane has the keys, and no page window may take them for it. `debug.cef` says whether
/// this process runs a pump and which wire counters it has.
@MainActor struct HostPageDebugInputTests {
    private static let checked: Set<InputInvariant> = [.responderMatches, .chromiumMatches, .keyWindowOwned]

    /// One key window focused on a hosted Chromium page, `tab_web` in `pane_a`; `pane_b` shows another hosted
    /// page, `tab_other`. `childPage` is the applier's embedder-active page: for a focused hosted page the
    /// applier focuses it as it does an in-process page (`FocusEffectApplier.focusPage`), so it is `tab_web`.
    private func observation(childPage: String? = "tab_web", keyWindow: InputObservation.KeyWindow = .window("window_1"),
                             windowKey: Bool = true) -> InputObservation {
        var model = FocusState()
        model.resolved = .browserPage(pane: "pane_a", tab: "tab_web")
        model.underlying = model.resolved
        model.windowKey = windowKey
        let window = InputObservation.Window(
            id: "window_1", model: model, responder: .content(pane: "pane_a"), responderClass: "ChromiumHostPageView",
            isKey: windowKey, layoutFocus: nil, ghosttyFocused: [], childPage: childPage,
            presented: ["pane_a": "tab_web", "pane_b": "tab_other"], childWindowTabs: [], hostPageTabs: ["tab_other", "tab_web"])
        return InputObservation(windows: [window], keyWindow: keyWindow, paletteOpen: false, activeWindow: "window_1",
                                context: FocusState.Context())
    }

    private func violations(_ observation: InputObservation) -> [InputViolation] {
        InputInvariants.world(observation).violations.filter { Self.checked.contains($0.invariant) }
    }

    /// The page view in the pane has the keys (no page window) and the applier's active page is the focused tab.
    @Test func aFocusedHostedPageWhosePageViewHasTheKeysIsInSync() {
        #expect(violations(observation()).isEmpty)
    }

    @Test func anotherHostedPageActiveWhileTheModelTargetsThisOneIsAChromiumViolation() {
        let found = violations(observation(childPage: "tab_other"))
        #expect(found.contains { $0.invariant == .chromiumMatches && $0.detail.contains("tab_other != model tab_web") })
    }

    @Test func noActivePageWhileTheModelTargetsAHostedPageIsAChromiumViolation() {
        let found = violations(observation(childPage: nil))
        #expect(found.contains { $0.invariant == .chromiumMatches && $0.detail.contains("nil != model tab_web") })
    }

    @Test func anActivePageTheModelDoesNotTargetIsAChromiumViolation() {
        let found = violations(observation(childPage: "tab_gone"))
        #expect(found.contains { $0.invariant == .chromiumMatches && $0.detail.contains("tab_gone") })
    }

    @Test func aPageWindowWithTheKeysWhileAHostedPageIsTargetedIsAKeyWindowViolation() {
        let found = violations(observation(keyWindow: .childPage(window: "window_1"), windowKey: false))
        #expect(found.contains { $0.invariant == .keyWindowOwned && $0.detail.contains("hosted browserPage") })
    }

    @Test func hostModeIsPumpFreeAndInProcessIsNot() {
        let hosted = DebugCEF.engineCounters(backend: .host, pump: nil, tracker: CEFTrackerStats())
        #expect(hosted["pump_free"] == .bool(true))
        let pumpLeftInHostMode = DebugCEF.engineCounters(backend: .host, pump: CEFPumpStats(), tracker: CEFTrackerStats())
        #expect(pumpLeftInHostMode["pump_free"] == .bool(false), "a pump in this process while the host runs Chromium")
        let local = DebugCEF.engineCounters(backend: .inProcess, pump: CEFPumpStats(), tracker: CEFTrackerStats())
        #expect(local["pump_free"] == .bool(false))
    }

    @Test func theHostWireIsNullWithoutAnAttachedHost() {
        #expect(DebugCEF.hostWire(nil) == .null)
    }

    /// No input method request waits on the host, so `ime_sync_requests` is 0, never null; only the input
    /// ring's counters, which nothing counts yet (tasks 041 and 042), stay null.
    @Test func theHostWireReportsNoSyncInputMethodRequests() throws {
        let stats = try #require(ChromiumHostRemoteWireStats(fields: [0, 0, 0, 0, 0, 0, 0]))
        guard case .object(let fields) = DebugCEF.hostWire(stats) else {
            Issue.record("host_wire is not an object")
            return
        }
        #expect(fields["ime_sync_requests"] == .number(0))
        #expect(fields["ring_depth"] == .null)
        #expect(fields["unacked_seq"] == .null)
        #expect(fields["quota_excess"] == .number(0))
    }

    @Test func pageWindowsExistOnlyInProcess() {
        #expect(ChildPageGeometry.hasPageWindows(.inProcess))
        #expect(!ChildPageGeometry.hasPageWindows(.host), "debug.key and debug.mouse never look for a page window in host mode")
    }
}
