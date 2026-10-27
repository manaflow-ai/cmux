import CmuxNextActions
import class CmuxSafeConcurrency.Invariant
import os

/// The action contract's App leg for the tab, pane (with columns), screen
/// (with screen groups), and terminal categories: every catalog action there has a
/// handler, even if only a typed "unavailable" one. `LaunchMenuAndBindingsTests`
/// holds it in every build; the launch check below runs in Debug builds only, so a
/// Release launch walks no catalog (startup-DESIGN.md row O12).
enum HandlerCoverage {
    static let categories: Set<ActionCategory> = [.tab, .pane, .screen, .terminal]

    /// Debug builds: logs how many catalog actions have no handler and stops at a missing one in
    /// ``categories``. Release builds: nothing.
    static func verifyAtLaunch(_ registry: ActionRegistry) {
        #if DEBUG
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")
        logger.info("unbound catalog actions: \(registry.unboundActionIDs().count)")
        let missing = registry.unboundActionIDs(in: categories)
        guard !missing.isEmpty else { return }
        let list = missing.map(\.rawValue).joined(separator: ", ")
        logger.fault("unbound actions: \(list, privacy: .public)")
        Invariant.debugCheck(false, "core-actions-have-handlers", "tab/pane/terminal actions without a handler: \(list)")
        #endif
    }
}
