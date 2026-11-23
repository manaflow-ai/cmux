public import CmuxNextDesign

/// `tabs.shellIconTheme` (Leo 2026-10-21: "AND WHERE THE F*** ARE THE ICONS FOR THE F***ING MACHINES"): with
/// `machine`, a shell tab draws the icon of the machine its shell runs on in its leading slot, this Mac's
/// included, so every shell tab carries one and none sticks out. A tab that is no plain shell (an agent's
/// mark, an exited terminal, a chat, a page, an icon the person set) keeps its own icon.
extension TabItem {
    /// Puts `machineIcon` in place of the `>_` kind glyph under the `machine` theme. Only a tab whose icon is
    /// still `TabIcon.terminal` changes; `default`, or a machine with no icon, leaves the glyph. The App applies
    /// it before the person's own icon (`TabItemMapping.applyUserIcon`), which still wins.
    public mutating func applyShellIconTheme(_ theme: TabShellIconTheme, machineIcon: @autoclosure () -> TabIcon?) {
        guard theme == .machine, icon == .terminal, let machineIcon = machineIcon() else { return }
        icon = machineIcon
    }

    /// A machine's shell tab icon: `registry`, its icon in the home session registry as a tab draws it
    /// (`TabUserIcon`: an emoji, an SF Symbol, a stored image once read), as its sidebar header shows it;
    /// else a Cloud machine's cloud; else `deviceSymbol`, the SF Symbol of the device it is (its daemon's
    /// `machine_symbol`). Nil: none known yet, and the tab keeps its `>_`.
    public static func shellMachineIcon(registry: TabIcon?, isCloud: Bool, deviceSymbol: String?) -> TabIcon? {
        if let registry { return registry }
        if isCloud { return .symbol("cloud") }
        return deviceSymbol.flatMap { $0.isEmpty ? nil : .symbol($0) }
    }
}
