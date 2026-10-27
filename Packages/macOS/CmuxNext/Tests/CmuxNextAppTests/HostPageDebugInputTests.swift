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

    /// One key window focused on a hosted Chromium page in `pane_a`.
    private func observation(childPage: String? = nil, keyWindow: InputObservation.KeyWindow = .window("window_1"),
                             windowKey: Bool = true) -> InputObservation {
        var model = FocusState()
        model.resolved = .browserPage(pane: "pane_a", tab: "tab_web")
        model.underlying = model.resolved
        model.windowKey = windowKey
        let window = InputObservation.Window(
            id: "window_1", model: model, responder: .content(pane: "pane_a"), responderClass: "ChromiumHostPageView",
            isKey: windowKey, layoutFocus: nil, ghosttyFocused: [], childPage: childPage, presented: ["pane_a": "tab_web"],
            childWindowTabs: [], hostPageTabs: ["tab_web"])
        return InputObservation(windows: [window], keyWindow: keyWindow, paletteOpen: false, activeWindow: "window_1",
                                context: FocusState.Context())
    }

    private func violations(_ observation: InputObservation) -> [InputViolation] {
        InputInvariants.world(observation).violations.filter { Self.checked.contains($0.invariant) }
    }

    @Test func aFocusedHostedPageWhosePageViewHasTheKeysIsInSync() {
        #expect(violations(observation()).isEmpty)
    }

    @Test func pageWindowFocusOnAHostedPageIsAChromiumViolation() {
        let found = violations(observation(childPage: "tab_web"))
        #expect(found.contains { $0.invariant == .chromiumMatches && $0.detail.contains("hosted page tab_web") })
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

    @Test func pageWindowsExistOnlyInProcess() {
        #expect(ChildPageGeometry.hasPageWindows(.inProcess))
        #expect(!ChildPageGeometry.hasPageWindows(.host), "debug.key and debug.mouse never look for a page window in host mode")
    }
}
