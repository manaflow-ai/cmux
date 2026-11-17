import AppKit
import CmuxNextDesign

// A workspace row's close, menu button, Unpin, tree fold and audio controls, each made the first time it shows
// (`RowControlSlot`, REOPEN-F7). Each maker reads the row's state for that control, so the row stays its one owner:
// the press calls the row's callback, the icon and label come from the row's model, the frame from its last layout.
extension WorkspaceRowView {
    /// Where the row's last layout put the menu button, made or not: the menu anchors there (`SidebarRowMenu`).
    var moreFrame: NSRect { moreSlot.frame }

    func makeCloseButton() -> SidebarIconButton {
        let button = SidebarIconButton.rowClose(label: Strings.closeButton)
        button.onPress = { [weak self] in self?.onClose?() }
        identify(button, as: "close")
        return button
    }

    func makeMoreButton() -> OverflowButton {
        let button = OverflowButton(label: Strings.workspaceMenu)
        button.onPress = { [weak self] in self?.onMore?() }
        button.showsMenu = showsMenu
        identify(button, as: "more")
        return button
    }

    func makePinButton() -> SidebarIconButton {
        let button = SidebarIconButton(icon: .statePinned, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.unpinWorkspace)
        button.onPress = { [weak self] in self?.onPin?() }
        identify(button, as: "pin")
        return button
    }

    func makeTreeFoldButton() -> SidebarIconButton {
        let button = SidebarIconButton(icon: .disclosureExpanded, pointSize: { Metrics.smallIconSize - Metrics.space2 },
                                       label: Strings.collapseSessions)
        button.onPress = { [weak self] in self?.onToggleTree?() }
        applyTreeFold(button)
        return button
    }

    func makeAudioButton() -> SidebarIconButton {
        let button = SidebarIconButton(icon: .browserTabAudio, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.muteTabs)
        button.onPress = { [weak self] in self?.onToggleAudio?() }
        applyAudio(button)
        return button
    }

    /// The speaker shows while the workspace's tabs play or are muted, crossed out while muted.
    func applyAudio(_ button: SidebarIconButton) {
        button.isHidden = audio == nil
        button.icon = audio == .muted ? .browserTabMuted : .browserTabAudio
        button.label = audio == .muted ? Strings.unmuteTabs : Strings.muteTabs
    }

    /// The chevron says what a press does: open a folded subtree or fold an open one.
    func applyTreeFold(_ button: SidebarIconButton) {
        button.icon = treeFold == .collapsed ? .disclosureCollapsed : .disclosureExpanded
        button.label = treeFold == .collapsed ? Strings.expandSessions : Strings.collapseSessions
    }

    /// The made controls' accessibility identifiers, for the row's workspace.
    func applyControlIdentifiers() {
        closeSlot.made.map { identify($0, as: "close") }
        moreSlot.made.map { identify($0, as: "more") }
        pinSlot.made.map { identify($0, as: "pin") }
    }

    private func identify(_ button: NSView, as control: String) {
        guard let id = lastConfiguration?.0.id else { return }
        button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(id.rawValue).\(control)")
    }
}
