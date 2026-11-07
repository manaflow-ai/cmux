import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// cmux#37366: every workspace of one window moved to another window showed in neither. New Window opens a new space,
/// so the receiving window showed another space than theirs: it listed them unseen, and the window they left closed.
/// Move Workspace to Window (the action; a drag between windows takes the same `WindowManager.moveWorkspaces`)
/// now keeps their space and switches the receiving window to it, so they show there and the first is selected.
/// Runs the real action and registry transition over a home daemon with two spaces (`GatherWindowsTests`).
@MainActor @Suite(.serialized, .closesItsWindows)
struct MoveWorkspacesToWindowSpaceTests {
    private static func moveInvocation(_ workspace: String, to window: WindowController, origin: ActionOrigin = .user) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .workspace, id: workspace),
                         arguments: ["window": .target(ActionTargetRef(kind: .window, id: window.state.id))], origin: origin)
    }

    /// The reported case: every workspace of a window moved, one after the other, into a window on another space.
    @Test func everyWorkspaceOfAWindowShowsInTheWindowItMovedTo() throws {
        let services = try GatherWindowsTests.services()
        defer { GatherWindowsTests.closeAll(services) }
        AppActions.bind(services)
        let source = try GatherWindowsTests.open(["k0", "k1"], services), target = try GatherWindowsTests.open(["k2", "k3"], services)
        #expect(source.state.profileID == GatherWindowsTests.rooms[0])
        #expect(target.state.profileID == GatherWindowsTests.rooms[1])

        #expect(services.registry.perform("moveWorkspaceToWindow", invocation: Self.moveInvocation("k1", to: target)))
        #expect(services.registry.perform("moveWorkspaceToWindow", invocation: Self.moveInvocation("k0", to: target)))

        let registry = services.windows.registry.value
        #expect(registry.window(source.state.id) == nil, "the emptied window stayed")
        #expect(registry.window(target.state.id)?.workspaceIDs.sorted() == ["k0", "k1", "k2", "k3"])
        #expect(target.state.profileID == GatherWindowsTests.rooms[0], "the window stayed on a space that does not show them")
        #expect(target.state.workspaceID == "k0", "the first moved workspace was not selected")
        let shown = WindowProfiles.shown(registry.members(of: target.state.id), profile: target.state.profileID, machines: services.machines)
        #expect(Set(shown).isSuperset(of: ["k0", "k1"]), "the moved workspaces are listed but not shown: \(shown)")
        // Their space did not change: the window's own workspaces are one space switch away, as before.
        #expect(WindowProfiles.shown(["k2", "k3"], profile: GatherWindowsTests.rooms[1], machines: services.machines) == ["k2", "k3"])
    }

    /// Into a window already on their space nothing switches.
    @Test func aMoveWithinOneSpaceKeepsTheWindowsSpace() throws {
        let services = try GatherWindowsTests.services()
        defer { GatherWindowsTests.closeAll(services) }
        AppActions.bind(services)
        let source = try GatherWindowsTests.open(["k2"], services), target = try GatherWindowsTests.open(["k3"], services)

        #expect(services.registry.perform("moveWorkspaceToWindow", invocation: Self.moveInvocation("k2", to: target)))

        #expect(services.windows.registry.value.window(source.state.id) == nil)
        #expect(target.state.profileID == GatherWindowsTests.rooms[1])
        #expect(target.state.workspaceID == "k2")
    }

    /// A CLI or MCP run without view-change permission moves them but leaves the window's space and selection.
    @Test func aMoveWithoutViewPermissionKeepsTheView() throws {
        let services = try GatherWindowsTests.services()
        defer { GatherWindowsTests.closeAll(services) }
        AppActions.bind(services)
        let source = try GatherWindowsTests.open(["k0", "k1"], services), target = try GatherWindowsTests.open(["k2", "k3"], services)
        services.windows.select("k3", in: target.state)

        try ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            #expect(services.registry.perform("moveWorkspaceToWindow", invocation: Self.moveInvocation("k0", to: target, origin: .cli)))
        }

        #expect(services.windows.registry.value.window(source.state.id)?.workspaceIDs == ["k1"])
        #expect(target.state.profileID == GatherWindowsTests.rooms[1], "the run switched the window's space")
        #expect(target.state.workspaceID == "k3", "the run changed the window's selection")
    }
}
