import CmuxNextActions
import os

/// The action contract's App leg for the tab, pane (with columns and
/// screens), and terminal categories: every catalog action there has a
/// handler, even if only a typed "unavailable" one. Debug builds stop at
/// launch when one is missing; release builds log a fault.
enum HandlerCoverage {
    static let categories: Set<ActionCategory> = [.tab, .pane, .terminal]

    static func verify(_ registry: ActionRegistry) {
        let missing = registry.unboundActionIDs(in: categories)
        guard !missing.isEmpty else { return }
        let list = missing.map(\.rawValue).joined(separator: ", ")
        Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions").fault("unbound actions: \(list, privacy: .public)")
        assertionFailure("tab/pane/terminal actions without a handler: \(list)")
    }
}
