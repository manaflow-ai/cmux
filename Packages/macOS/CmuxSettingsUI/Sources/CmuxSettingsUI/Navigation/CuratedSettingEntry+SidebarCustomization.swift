import Foundation

extension Array where Element == CuratedSettingEntry {
    /// `entries` with ``sidebarCustomizationEntries`` placed right after the
    /// Match Terminal Background entry, where the rows sit in Settings >
    /// Sidebar. A call rather than splitting ``cmuxDefault(catalog:)``'s
    /// large literal keeps its contextual type concrete.
    static func insertingSidebarCustomizationEntries(into entries: [CuratedSettingEntry]) -> [CuratedSettingEntry] {
        var result = entries
        let anchor = result.firstIndex { $0.section == .sidebarAppearance && $0.id == "match-terminal" }
        result.insert(contentsOf: sidebarCustomizationEntries, at: anchor.map { $0 + 1 } ?? result.endIndex)
        return result
    }

    /// Search entries for the sidebar glass, peek, density and drag rows
    /// (`SidebarSection+Customization`), in row order.
    static var sidebarCustomizationEntries: [CuratedSettingEntry] {
        [
            .init(section: .sidebarAppearance, id: "sidebar-glass-tint", title: String(localized: "settings.sidebar.tintOpacity", defaultValue: "Tint Opacity"), synonyms: "sidebarAppearance.tintOpacity sidebarTintOpacity glass glassmorphism tint opacity transparency blur floating docked panel peek clear frosted opaque"),
            .init(section: .sidebarAppearance, id: "sidebar-liquid-glass", title: String(localized: "settings.sidebar.liquidGlass", defaultValue: "Liquid Glass"), synonyms: "sidebarAppearance.compositorGlass sidebarCompositorGlass liquid glass blur compositor frosted transparency see-through backdrop"),
            .init(section: .sidebarAppearance, id: "sidebar-tint-color", title: String(localized: "settings.sidebar.tintColor", defaultValue: "Tint Color"), synonyms: "sidebarAppearance.tintColor sidebarTintHex tint colour color glass hex grey gray"),
            .init(section: .sidebarAppearance, id: "sidebar-glass-blur", title: String(localized: "settings.sidebar.blurOpacity", defaultValue: "Blur Opacity"), synonyms: "blur opacity sidebarAppearance.glassBlurRadius sidebarGlassBlurRadius blur radius glass frosted clear see-through transparency backdrop compositor"),
            .init(section: .sidebarAppearance, id: "sidebar-row-hover", title: String(localized: "settings.sidebar.rowHover", defaultValue: "Row Hover"), synonyms: "sidebarRowHover row hover highlight pointer mouse wash workspace list"),
            .init(section: .sidebarAppearance, id: "sidebar-peek-reveal", title: String(localized: "settings.sidebar.peekReveal", defaultValue: "Sidebar Peek Reveal Speed"), synonyms: "sidebar.peekReveal peek hover reveal edge dwell instant quick relaxed sensitivity floating sidebar"),
            .init(section: .sidebarAppearance, id: "sidebar-peek-disabled", title: String(localized: "settings.sidebar.peekDisabled", defaultValue: "Disable Sidebar Peek"), synonyms: "sidebar.peekDisabled peek hover reveal disable never auto hide floating sidebar edge"),
            .init(section: .sidebarAppearance, id: "sidebar-row-density", title: String(localized: "settings.sidebar.rowDensity", defaultValue: "Row Density"), synonyms: "sidebar.rowDensity density compact cozy spacious row height padding workspace list"),
            .init(section: .sidebarAppearance, id: "sidebar-drag-switch", title: String(localized: "settings.sidebar.dragSwitchDisabled", defaultValue: "Disable Switch on Drag"), synonyms: "sidebar.dragSwitchDisabled drag reorder switch selection workspace pick up")
        ]
    }
}
