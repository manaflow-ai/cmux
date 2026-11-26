import CmuxNextActions
import CmuxNextLayout
import CmuxNextBridge
import CmuxNextWindowRules

/// Up-front availability of column actions: on a screen's only column, widths and moves read "Add a second column
/// first" on the menu item instead of failing after the click (docking stays enabled: DockColumnHandlers), and Undock
/// is disabled on a column that is not docked. The rule and its ids are Rust's (`chat::column_availability`); the
/// column is ``ColumnHandlers/target(_:_:refusing:)``'s, which never refuses here.
enum ColumnAvailability {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let rules = WindowRules()
        for id in (rules.columnActions()?.loneColumnDisabled ?? []) + ["column.undock"] {
            ActionTargetReasons.set(ActionID(rawValue: id), in: registry) { invocation in
                guard let (_, screen, column) = ColumnHandlers.target(invocation, ctx, refusing: false) else { return nil }
                return switch rules.columnAvailability(id, column: ColumnHandlers.facts(column, of: screen)) {
                case .addSecondColumn?: RefusalStrings.addSecondColumnFirst
                case .notDocked?: RefusalStrings.columnNotDocked
                case nil: nil
                }
            }
        }
    }
}
