import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// DOCK-WIRE (R87): on a daemon without `dock-columns-v1` (an older remote
/// machine, or one from before the dock rename) every dock action refuses
/// with the capability it lacks. None runs and silently drops the change.
@MainActor
struct DockColumnCapabilityTests {
    @Test func dockActionsRefuseWithTheMissingCapability() {
        let services = ActionBindingCoverageTests.boundServices()
        #expect(!services.daemon.supports("dock-columns-v1"))
        for id: ActionID in ["column.dock", "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
                   "column.float", "column.undock", "tab.moveToNewDockColumn"] {
            let reason = services.registry.unavailableReason(for: id)
            #expect(reason.map(CapabilityRefusalTests.gateReasons.contains) == true, "\(id): \(reason ?? "nil")")
            #expect(ActionBindingCoverageTests.run(services, id.rawValue) == .refused(reason ?? ""), "\(id)")
        }
    }
}
