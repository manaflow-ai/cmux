import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// Sidebar Density: Compact / Comfortable / Expanded (cx-13w3; palette and
/// the sidebar's Options). Each writes `sidebar.density`, so the choice follows cmux.json;
/// the menu hides the current one and offers the others.
enum SidebarDensityActions {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let current = { (context.services.settings?.snapshot.sidebarSections ?? .defaults).density }
        let choices: [(ActionID, SidebarDensity)] = [
            ("sidebar.density.compact", .compact), ("sidebar.density.comfortable", .comfortable), ("sidebar.density.expanded", .expanded),
        ]
        for (id, value) in choices {
            registry.bind(id, unavailable: { nil }) { invocation in
                guard current() != value else { return }
                try SidebarGroupByActions.write(SidebarSectionsSetting.densityPath, .string(value.rawValue), invocation, context)
            }
            ActionTargetVisibility.hide(id, in: registry) { _ in current() == value }
        }
    }
}
