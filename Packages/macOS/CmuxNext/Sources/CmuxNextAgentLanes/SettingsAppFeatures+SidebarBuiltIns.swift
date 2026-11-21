public import CmuxNextActions
public import CmuxNextApps
public import CmuxNextSidebar

extension SettingsAppFeatures.SidebarItems {
    /// App Store Features' Sidebar cards (edit mode's Add Items): every built-in item the Features tab lists, beside
    /// the Chief's own card. Get is Add to Sidebar (`sidebar.item.add`), Remove takes every such item out
    /// (`sidebar.item.removeEverywhere`), both as the person's edit.
    ///
    /// - Parameters:
    ///   - chief: The Chief's own answer for its card (``ChiefSidebar``), kept as it is; nil: no Chief card.
    ///   - document: The sidebar layout in effect, read each time a card asks whether its item is shown.
    ///   - registry: Where the adds and removes run.
    /// - Returns: The cards' answers: the Chief's from `chief`, every other one from `document` and `registry`.
    @MainActor
    public static func builtIns(over chief: Self?, document: @escaping @MainActor () -> SidebarLayoutDocument,
                                registry: ActionRegistry) -> Self {
        // Every sidebar item the Features tab lists but the Chief's, so a new card needs no change here.
        let items = Set(AppFeature.catalog.compactMap(\.sidebarItem)).subtracting([SidebarBuiltIn.chief.rawValue])
        return .init(names: items.union(chief?.names ?? []), isShown: { name in
            guard items.contains(name) else { return chief?.isShown(name) == true }
            // Home is an app now (R63), as Add to Sidebar adds it.
            guard let builtIn = SidebarBuiltIn(rawValue: name) else { return false }
            return document().firstItem(with: SidebarLayoutDocument.firstPartyApps[builtIn].map(LayoutItemRef.app) ?? .builtIn(builtIn)) != nil
        }, set: { [weak registry] name, on in
            guard items.contains(name) else { return chief?.set(name, on) == true }
            let invocation = on ? ActionInvocation(arguments: ["item": .string(name)], origin: .user)
                : ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: name), origin: .user)
            return registry?.perform(on ? "sidebar.item.add" : "sidebar.item.removeEverywhere", invocation: invocation) == true
        })
    }
}
