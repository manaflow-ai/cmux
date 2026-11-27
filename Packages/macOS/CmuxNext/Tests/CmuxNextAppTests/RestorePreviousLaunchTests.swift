import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// Restore Previous App Launch (`reopenPreviousSession`, Cmd-Shift-O, `workspace
/// restore-previous-app-launch`): the windows open when the app last quit come back at launch;
/// this action reopens the ones of them closed since, and the workspaces closed since from them,
/// through the daemon's closed history (the one reopen path).
@MainActor @Suite(.serialized)
struct RestorePreviousLaunchTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test func restorePreviousAppLaunchIsAnAvailableAction() {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: "reopenPreviousSession") == nil)
    }

    /// A launch that restored nothing (no saved windows): nothing to reopen, said in words.
    @Test func withNothingFromThePreviousLaunchItRefusesWithAReason() {
        let services = Self.services()
        let refusal = services.registry.capturingRefusal {
            _ = services.registry.perform("reopenPreviousSession", invocation: ActionInvocation(origin: .cli))
        }
        #expect(refusal == "Nothing from the previous app launch to restore")
    }

    // MARK: The plan

    static func item(_ id: String, _ kind: ClosedItem.Kind, at ms: UInt64, window: String?, group: Bool = false) -> ClosedItem {
        var item = ClosedItem(id: id, kind: kind, closedAtMs: ms,
                              group: group ? ClosedItem.Group(id: "g1", name: "Group") : nil)
        item.window = window
        return item
    }

    /// Window A (open at the last quit, closed in this launch) comes back by its window item;
    /// window C (closed before the last quit) and window B (still open) do not. Workspaces closed
    /// in this launch from a window of the last quit come back, oldest close first; one closed
    /// before this launch, one from a window this launch opened, and a deleted group do not.
    @Test func thePlanReopensWhatThePreviousLaunchLeftOpenAndThisLaunchClosed() {
        let launch = PreviousLaunch(windowIDs: ["A", "B"], restoredAtMs: 1_000)
        let registry = WindowRegistry(windows: [
            .init(id: "A", workspaceIDs: ["a"], isOpen: false),
            .init(id: "B", workspaceIDs: ["b"]),
            .init(id: "C", workspaceIDs: ["c"], isOpen: false),
            .init(id: "N", workspaceIDs: ["n"]),
        ])
        let closed = [
            Self.item("closed_wsB2", .workspace, at: 1_500, window: "inst/B"),
            Self.item("closed_winA", .window, at: 1_400, window: "inst/A"),
            Self.item("closed_winC", .window, at: 500, window: "inst/C"),
            Self.item("closed_wsB1", .workspace, at: 1_200, window: "inst/B"),
            Self.item("closed_wsOld", .workspace, at: 900, window: "inst/B"),
            Self.item("closed_wsN", .workspace, at: 1_300, window: "inst/N"),
            Self.item("closed_group", .workspace, at: 1_350, window: "inst/B", group: true),
            Self.item("closed_tab", .tab, at: 1_360, window: "inst/B"),
        ]
        let plan = launch.plan(closed: closed, registry: registry, install: "inst")
        #expect(plan.closedIDs == ["closed_winA", "closed_wsB1", "closed_wsB2"])
        #expect(plan.windowIDs.isEmpty)
    }

    /// A daemon without window records records no window item: a closed window of the previous
    /// launch reopens directly, and nothing else names its window.
    @Test func aClosedWindowWithoutAWindowItemReopensDirectly() {
        let launch = PreviousLaunch(windowIDs: ["A"], restoredAtMs: 1_000)
        let registry = WindowRegistry(windows: [.init(id: "A", workspaceIDs: ["a"], isOpen: false), .init(id: "B", workspaceIDs: ["b"])])
        #expect(launch.plan(closed: [], registry: registry, install: nil) == PreviousLaunch.Plan(windowIDs: ["A"]))
        let reopened = WindowRegistry(windows: [.init(id: "A", workspaceIDs: ["a"])])
        #expect(launch.plan(closed: [], registry: reopened, install: "inst").isEmpty, "every window is open again")
    }
}
