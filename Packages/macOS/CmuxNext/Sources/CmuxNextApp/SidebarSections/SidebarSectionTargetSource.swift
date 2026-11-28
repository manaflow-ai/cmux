import CmuxNextActions
import CmuxNextPalette
import CmuxNextSidebar

/// Palette target lists for sidebar section actions: every section and
/// item of the layout. Other kinds fall through to `next`.
final class SidebarSectionTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        let doc = services.sidebarLayout.document
        switch kind {
        case .sidebarSection:
            return doc.sections.map { section in
                let title = section.title ?? (section.content == .workspaces ? SidebarSectionStrings.workspacesSection
                    : section.items.first.map { SidebarItemInfo.fallback(for: $0.ref).title } ?? SidebarSectionStrings.untitledSection)
                return PaletteTargetOption(id: section.id.rawValue, title: title, subtitle: section.region.rawValue, symbol: "rectangle.stack")
            }
        case .sidebarItem:
            return doc.sections.flatMap(\.items).map { item in
                let info = SidebarItemInfo.fallback(for: item.ref)
                return PaletteTargetOption(id: item.id.rawValue, title: info.title, symbol: info.symbol)
            }
        default:
            return next.targets(of: kind)
        }
    }

    /// A section's own title; nil for an untitled one, whose listed label
    /// ("Workspaces", its first item) is not a name to rename from.
    func title(of target: ActionTargetRef) -> String? {
        switch target.kind {
        case .sidebarSection:
            services.sidebarLayout.document.sections.first { $0.id.rawValue == target.id }?.title.flatMap { $0.isEmpty ? nil : $0 }
        case .sidebarItem:
            targets(of: .sidebarItem).first { $0.id == target.id }?.title
        default:
            next.title(of: target)
        }
    }
}
