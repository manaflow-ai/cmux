@testable import CmuxNextControl
import Testing

/// A bare public id passed as `target` to an action that takes more than one kind
/// (`agent.openSessionTab`: a pane or a tab) resolves as the kind its prefix names. It
/// resolved as the action's first kind, so `app_agent_open_tab {target: "tab_…"}`, which the
/// cmux-subsessions instructions tell agents to send, looked the tab up among panes and
/// failed with not_found.
@Suite struct ControlTargetKindPrefixTests {
    @Test func aBareIdResolvesAsTheKindItsPrefixNames() throws {
        let kinds = ["pane", "tab"]
        let tab = try ControlRouter.target(from: .string("tab_0a1b"), allowedKinds: kinds, knownKinds: kinds, action: "x")
        #expect(tab == ControlTargetRef(kind: "tab", id: "tab_0a1b"))
        let pane = try ControlRouter.target(from: .string("pane_0a1b"), allowedKinds: kinds, knownKinds: kinds, action: "x")
        #expect(pane == ControlTargetRef(kind: "pane", id: "pane_0a1b"))
        let workspace = try ControlRouter.target(from: .string("ws_0a1b"), allowedKinds: ["tab", "workspace"],
                                                 knownKinds: ["tab", "workspace"], action: "x")
        #expect(workspace == ControlTargetRef(kind: "workspace", id: "ws_0a1b"))
    }

    @Test func anIdWithNoKnownPrefixStillResolvesAsTheFirstKind() throws {
        let kinds = ["pane", "tab"]
        let short = try ControlRouter.target(from: .string("0a1b"), allowedKinds: kinds, knownKinds: kinds, action: "x")
        #expect(short == ControlTargetRef(kind: "pane", id: "0a1b"))
        let explicit = try ControlRouter.target(from: .string("tab:pane_0a1b"), allowedKinds: kinds, knownKinds: kinds, action: "x")
        #expect(explicit == ControlTargetRef(kind: "tab", id: "pane_0a1b"))
    }
}
