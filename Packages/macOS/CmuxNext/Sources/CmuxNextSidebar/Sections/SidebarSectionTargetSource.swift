public import CmuxNextActions
public import CmuxNextPalette

/// Palette target lists for sidebar section actions: every section and
/// item of the layout. Other kinds fall through to `next`.
public final class SidebarSectionTargetSource: PaletteTargetSource {
    private let document: @MainActor () -> SidebarLayoutDocument
    private let workspacesTitle: String
    private let untitledTitle: String
    private let next: any PaletteTargetSource

    public init(document: @escaping @MainActor () -> SidebarLayoutDocument, workspacesTitle: String,
                untitledTitle: String, next: any PaletteTargetSource) {
        (self.document, self.workspacesTitle, self.untitledTitle, self.next) = (document, workspacesTitle, untitledTitle, next)
    }

    public func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        let doc = document()
        switch kind {
        case .sidebarSection:
            return doc.sections.map { section in
                let title = section.title ?? (section.content == .workspaces ? workspacesTitle
                    : section.items.first.map { SidebarItemInfo.fallback(for: $0.ref).title } ?? untitledTitle)
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

    /// Hide App lists both item and section contributions that have an app owner.
    public func appTargets() -> [PaletteTargetOption] {
        let doc = document()
        return [ActionTargetKind.sidebarItem, .sidebarSection].flatMap { kind in
            targets(of: kind).compactMap { option in
                let target = ActionTargetRef(kind: kind, id: option.id)
                let app = kind == .sidebarItem ? doc.item(LayoutItemID(option.id))?.owningAppID : doc.section(LayoutSectionID(option.id))?.owningAppID
                guard app != nil else { return nil }
                var row = option
                row.id = target.description
                return row
            }
        }
    }

    /// A section's own title; nil for an untitled one, whose listed label
    /// ("Workspaces", its first item) is not a name to rename from.
    public func title(of target: ActionTargetRef) -> String? {
        switch target.kind {
        case .sidebarSection:
            document().sections.first { $0.id.rawValue == target.id }?.title.flatMap { $0.isEmpty ? nil : $0 }
        case .sidebarItem:
            targets(of: .sidebarItem).first { $0.id == target.id }?.title
        default:
            next.title(of: target)
        }
    }

    /// Descriptions belong to kinds `next` lists.
    public func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }
}
