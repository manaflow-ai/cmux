import CmuxNextActions
import CmuxNextSidebar

/// Sidebar section and item toggles read as the change they make on the
/// target (cx-w1r5, Lawrence 2026-10-09: "Show or Hide Label" was confusing):
/// each toggle's state picks its catalog title (Hide Label or Show Label, Hide
/// Section Title or Show Section Title, Collapse Section or Expand Section,
/// ActionToggleTitles), and a section's Hide row names the section.
enum SidebarSectionMenuTitles {
    @MainActor
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let doc = { services.sidebarLayout.document }
        ActionTargetTitles.setState("sidebar.item.toggleLabel", in: registry) { invocation in
            (try? SidebarSectionResolve.item(invocation.target, in: doc()))?.showsLabel
        }
        ActionTargetTitles.setState("sidebar.section.toggleTitle", in: registry) { invocation in
            (try? SidebarSectionResolve.section(invocation.target, in: doc()))?.showsTitle
        }
        ActionTargetTitles.setState("sidebar.section.toggleCollapsed", in: registry) { invocation in
            guard let model = services.windows.active?.sidebar.model,
                  let section = try? SidebarSectionResolve.section(invocation.target, in: model.layout) else { return nil }
            return model.collapsedLayoutSections.contains(section.id)
        }
        ActionTargetTitles.set("sidebar.section.hide", in: registry) { invocation in
            guard let section = try? SidebarSectionResolve.section(invocation.target, in: doc()) else { return nil }
            return name(of: section, services).map(SidebarSectionStrings.hide(named:))
        }
    }

    /// The name a section's Hide row shows: its own title, else its app's
    /// name; nil keeps the catalog title (Hide Section).
    @MainActor
    private static func name(of section: LayoutSection, _ services: AppServices) -> String? {
        if let title = section.title, !title.isEmpty { return title }
        guard let app = section.owningAppID, let record = services.apps.client.app(app) else { return nil }
        let name = record.manifest.name.resolved()
        return name.isEmpty ? nil : name
    }
}
