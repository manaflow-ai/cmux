#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextFocus
import CmuxNextInputModel
import CmuxNextOracle
import CmuxNextSettings
import Testing

/// The oracle's focus facet is `InputObservationBuilder.observe` in the snapshot
/// schema's form: public window ids, the model next to AppKit, Ghostty and the layout per window, and
/// each window consistent exactly when no world invariant violation names it.
/// Run: `swift test --filter OracleFocusFacetTests`.
@MainActor @Suite(.serialized) struct OracleFocusFacetTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    private static let keyWindow = "6F1C2A9E-0B3D-4E5F-8A7B-1C2D3E4F5A6B"
    private static let backWindow = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    /// A window focused on the terminal of its one pane, all outputs in sync unless `layoutFocus` differs.
    private func terminalWindow(_ id: String, pane: String, tab: String, isKey: Bool, layoutFocus: String) -> InputObservation.Window {
        var model = FocusState()
        model.topology = FocusTopology(workspace: "ws_1", panes: [.init(id: pane, tabs: [.init(id: tab, kind: .terminal)], selected: tab)])
        model.pane = pane
        model.resolved = .terminal(pane: pane, tab: tab)
        model.underlying = model.resolved
        model.windowKey = isKey
        model.context = FocusState.Context(terminal: true)
        model.generation = 7
        return InputObservation.Window(
            id: id, model: model, responder: .content(pane: pane), responderClass: "GhosttySurfaceView", isKey: isKey,
            layoutFocus: layoutFocus, ghosttyFocused: isKey ? [tab] : [], childPage: nil, presented: [pane: tab], topPage: false)
    }

    private func twoWindows(backLayoutFocus: String) -> InputObservation {
        InputObservation(
            windows: [terminalWindow(Self.keyWindow, pane: "pane_a", tab: "tab_a", isKey: true, layoutFocus: "pane_a"),
                      terminalWindow(Self.backWindow, pane: "pane_b", tab: "tab_b", isKey: false, layoutFocus: backLayoutFocus)],
            keyWindow: .window(Self.keyWindow), paletteOpen: false, activeWindow: Self.keyWindow,
            context: FocusState.Context(terminal: true))
    }

    /// The schema object `terminalWindow` gives for a window in sync.
    private func expectedWindow(_ id: String, pane: String, tab: String, isKey: Bool) -> OracleValue {
        let model: OracleValue = [
            "pane": .string(pane), "target": "content", "resolved": "terminal", "resolvedPane": .string(pane),
            "resolvedTab": .string(tab), "overlays": [], "dragging": false, "windowKey": .bool(isKey),
            "sidebarHidden": false, "generation": 7,
        ]
        let ghostty: OracleValue = isKey ? [.string(tab)] : []
        return [
            "id": .string(id), "isKey": .bool(isKey), "responder": "content", "responderPane": .string(pane),
            "layoutFocus": .string(pane),
            "ghosttyFocused": ghostty, "childPage": nil, "hasSheet": false, "topPage": false, "model": model,
            "consistent": true,
        ]
    }

    @Test func aSettledStateIsTheSchemaObjectWithPublicWindowIDs() {
        let facet = InputObservationBuilder.oracleFocus(twoWindows(backLayoutFocus: "pane_b"))
        let front = ControlWindowInfo.publicID(forKey: Self.keyWindow)
        let back = ControlWindowInfo.publicID(forKey: Self.backWindow)
        #expect(front == "win_6f1c2a9e0b3d4e5f8a7b1c2d3e4f5a6b")
        let windows: OracleValue = [
            expectedWindow(front, pane: "pane_a", tab: "tab_a", isKey: true),
            expectedWindow(back, pane: "pane_b", tab: "tab_b", isKey: false),
        ]
        let expected: OracleValue = [
            "windows": windows,
            "keyWindow": ["kind": "window", "window": .string(front)],
            "activeWindow": .string(front),
            "paletteOpen": false,
            "context": ["terminal": true, "browser": false, "agent": false],
        ]
        #expect(facet == expected)
    }

    /// W2 broken in the back window only: that window is inconsistent, the key window still is.
    @Test func aWindowIsInconsistentExactlyWhenItsInvariantsBreak() {
        let observation = twoWindows(backLayoutFocus: "pane_stale")
        #expect(InputInvariants.world(observation).violations.map(\.signature) == ["W2@\(Self.backWindow)"])
        let facet = InputObservationBuilder.oracleFocus(observation)
        guard case .array(let windows) = facet["windows"] else { Issue.record("no windows in \(facet)"); return }
        #expect(windows.map { $0["consistent"] } == [OracleValue.bool(true), OracleValue.bool(false)])
        #expect(windows[1]["layoutFocus"] == OracleValue.string("pane_stale"))
    }

    /// A pane that does not present the targeted tab yet (a `turn` checkpoint right after a new tab): the
    /// world invariants skip it, so it is not inconsistent. Settle state is `debug.oracle.settle`'s and I5's.
    @Test func anUnsettledWindowIsNotInconsistent() {
        var observation = twoWindows(backLayoutFocus: "pane_b")
        observation.windows[1].presented = ["pane_b": "tab_loading"]
        #expect(InputInvariants.world(observation).unsettled == [Self.backWindow])
        let facet = InputObservationBuilder.oracleFocus(observation)
        guard case .array(let windows) = facet["windows"] else { Issue.record("no windows in \(facet)"); return }
        #expect(windows.map { $0["consistent"] } == [OracleValue.bool(true), OracleValue.bool(true)])
    }

    /// The responder's pane is its own field: a terminal left in another pane than the model's shows there
    /// even where W1 does not run (a palette over the window resolves to an overlay, which W1 skips).
    @Test func theResponderPaneIsReportedWhereW1DoesNotCheckIt() {
        var observation = twoWindows(backLayoutFocus: "pane_b")
        observation.windows[0].model.overlays = [.palette]
        observation.windows[0].model.resolved = .overlay(.palette)
        observation.windows[0].responder = .content(pane: "pane_other")
        observation.paletteOpen = true
        let facet = InputObservationBuilder.oracleFocus(observation)
        guard case .array(let windows) = facet["windows"] else { Issue.record("no windows in \(facet)"); return }
        #expect(windows[0]["responder"] == OracleValue.string("content"))
        #expect(windows[0]["responderPane"] == OracleValue.string("pane_other"))
        #expect(windows[0]["model"]?["pane"] == OracleValue.string("pane_a"))

        observation.windows[0].responder = .sidebar
        let sidebar = InputObservationBuilder.oracleFocus(observation)
        guard case .array(let sidebarWindows) = sidebar["windows"] else { Issue.record("no windows in \(sidebar)"); return }
        #expect(sidebarWindows[0]["responder"] == OracleValue.string("sidebar"))
        #expect(sidebarWindows[0]["responderPane"] == OracleValue.null)
    }

    @Test func everyKeyWindowKindNamesItsCmuxWindow() {
        let front = OracleValue.string(ControlWindowInfo.publicID(forKey: Self.keyWindow))
        let cases: [(InputObservation.KeyWindow, OracleValue)] = [
            (.none, ["kind": "none", "window": nil]),
            (.window(Self.keyWindow), ["kind": "window", "window": front]),
            (.childPage(window: Self.keyWindow), ["kind": "childPage", "window": front]),
            (.panel(window: Self.keyWindow, kind: "NSPanel"), ["kind": "panel", "window": front]),
            (.panel(window: nil, kind: "NSPanel"), ["kind": "panel", "window": nil]),
            (.sheet(window: Self.keyWindow), ["kind": "sheet", "window": front]),
            (.other("NSWindow"), ["kind": "other", "window": nil]),
        ]
        for (keyWindow, expected) in cases {
            var observation = twoWindows(backLayoutFocus: "pane_b")
            observation.keyWindow = keyWindow
            #expect(InputObservationBuilder.oracleFocus(observation)["keyWindow"] == expected)
        }
    }

    private func router(_ control: OracleControl) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30)))
        router.register(control.methods)
        return router
    }

    private func focusRequest(_ id: String) -> ControlRequest {
        ControlRequest(id: .string(id), method: OracleControl.snapshot, params: ["facets": ["focus"]])
    }

    /// `debug.oracle.snapshot` over the app's own list answers `focus` from the live services, in the
    /// schema's form and not as the not-comparable answer of a facet with no provider.
    @Test func debugOracleSnapshotAnswersFocusFromTheAppList() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.makeOracleFacets().provided.contains(.focus))
        let reply = try await router(OracleControl(host: services)).handle(focusRequest("1")).get()
        let focus = try #require(reply["focus"]?.objectValue, "no focus object in \(reply)")
        #expect(Set(focus.keys) == ["windows", "keyWindow", "activeWindow", "paletteOpen", "context"])
        #expect(focus["windows"]?.arrayValue != nil)
        #expect(focus["paletteOpen"] == JSONValue.bool(false))
    }

    /// The facet over the wire: a two-window state through `debug.oracle.snapshot` arrives as the JSON
    /// object the schema describes, with public ids and the generation an integer.
    @Test func debugOracleSnapshotSendsTheFacetAsSchemaJSON() async throws {
        let observation = twoWindows(backLayoutFocus: "pane_stale")
        let control = OracleControl(facets: OracleFacets([OracleFacetSource(.focus, .mainActor {
            InputObservationBuilder.oracleFocus(observation)
        })]))
        let reply = try await router(control).handle(focusRequest("2")).get()
        let windows = try #require(reply["focus"]?["windows"]?.arrayValue, "no focus windows in \(reply)")
        let front = ControlWindowInfo.publicID(forKey: Self.keyWindow)
        #expect(windows.map { $0["id"]?.stringValue } == [front, ControlWindowInfo.publicID(forKey: Self.backWindow)])
        #expect(windows.map { $0["model"]?["generation"]?.intValue } == [7, 7])
        #expect(windows.map { $0["consistent"]?.boolValue } == [true, false])
        #expect(windows.map { $0["responderPane"]?.stringValue } == ["pane_a", "pane_b"])
        #expect(reply["focus"]?["keyWindow"] == JSONValue.object(["kind": "window", "window": .string(front)]))
    }
}
#endif
