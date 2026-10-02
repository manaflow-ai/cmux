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
}
