import Foundation

extension LayoutItemRef {
    /// True when a sidebar item with this ref switches on mouse-down, as a workspace row does.
    ///
    /// Home and the App Store only change what the window shows, so the switch
    /// is safe on the press, and a press that turns into a drag still moves the
    /// item (the switch already happened, as with a dragged workspace row).
    /// Every other item (Settings, launchers, links, apps) still acts on
    /// release, so a press the user meant as a move never runs it.
    var activatesOnPress: Bool {
        if let builtIn { return builtIn == .home || builtIn == .appStore }
        guard kind == Self.appKind else { return false }
        return value == SidebarLayoutDocument.firstPartyApps[.home] || value == SidebarLayoutDocument.firstPartyApps[.appStore]
    }
}
