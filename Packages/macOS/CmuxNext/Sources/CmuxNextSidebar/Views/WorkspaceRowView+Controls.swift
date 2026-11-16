import AppKit
import CmuxNextDesign

// A workspace row's close, menu button, Unpin, tree fold and audio controls, each made the first time it shows
// (`RowControlSlot`, REOPEN-F7). Each maker reads the row's state for that control, so the row stays its one owner:
// the press calls the row's callback, the icon and label come from the row's model, the frame from its last layout.
extension WorkspaceRowView {
    /// Where the row's last layout put the menu button, made or not: the menu anchors there (`SidebarRowMenu`).
    var moreFrame: NSRect { moreSlot.frame }

    func makeScreenButton() -> SidebarIconButton {
        let button = SidebarIconButton(icon: .remoteDisplay, pointSize: { Metrics.smallIconSize - Metrics.space1 }, label: Strings.viewScreen)
        button.onPress = { [weak self] in
            guard let self, let action = self.screenAction else { return }
            self.onScreenAction?(action)
        }
        identify(button, as: "screen")
        return button
    }

    func configureScreen(_ machine: SidebarMachine?) {
        let next: SidebarIntent?
        // A local row has no Share button (Leo 11-16: "JUST GET RID OF IT NOW"; the machine header and palette share).
        // While this Mac shares, the local rows carry the sharing badge instead, drawn on the row on screen only.
        let shared = machine?.kind == .local && machine?.screenShared == true && !isPlaceholderRow
        if let machine, !isPlaceholderRow {
            switch machine.kind {
            case .local: next = shared ? .shareScreen(.local) : nil
            case .cloud: next = .viewScreen(machine.id)
            case .ssh, .server: next = machine.screenDeviceID == nil ? nil : .viewScreen(machine.id)
            }
        } else {
            next = nil
        }
        if screenAction != next { screenAction = next; needsLayout = true }
        if screenShared != shared { screenShared = shared; needsLayout = true }
        if let machine, screenAction != nil {
            let button = screenSlot.control(in: self)
            button.isEnabled = shared || machine.kind == .cloud || machine.screenAvailable
            // A screen, never the generic share arrow (Leo 2026-11-16: "Holy moly is THIS the icon for screen
            // sharing???"). The sharing badge is the same screen in the accent.
            button.icon = .remoteDisplay
            button.tintOverride = shared ? Palette.accent : nil
            button.label = shared ? Strings.sharingScreen : Strings.viewScreen + (button.isEnabled ? "" : " — " + Strings.statusOffline)
            identify(button, as: "screen")
        } else {
            screenSlot.made?.isHidden = true
            screenSlot.made?.isEnabled = false
            screenSlot.made?.tintOverride = nil
        }
    }

    /// The local row on screen while this Mac shares: the workspace the people watching see.
    var showsSharingBadge: Bool { screenShared && (isSelected || isOnScreen) }

    /// View screen on hover and on the selected row, never on every row at rest (Leo 2026-11-16); the sharing badge
    /// on the shared row only. It takes the shared slot left of the hover cluster (`after`), over the title's faded
    /// end like ⋮ and ✕, so nothing moves and no slot is reserved at rest. Returns its leading edge when shown.
    func layoutScreen(rowWidth: CGFloat, cy: CGFloat, control: CGFloat, after cluster: [NSRect], fades: Bool) -> CGFloat? {
        let wanted = screenShared ? showsSharingBadge : revealsHoverControls || isSelected
        let shown = screenAction != nil && !isShowingPlaceholder && !renaming && wanted
        setHoverShown(screenSlot, shown, fades: fades)
        guard shown else { return nil }
        let center = SidebarStyle.trailingColumnCenterX(rowWidth: rowWidth)
        let next = cluster.map { Int(round((center - $0.midX) / SidebarStyle.trailingSlotPitch)) + 1 }.max() ?? 1
        screenSlot.frame = trailingActionFrame(rowWidth: rowWidth, cy: cy, control: control, minimumSlot: next)
        return screenSlot.frame.minX
    }

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
        screenSlot.made.map { identify($0, as: "screen") }
        closeSlot.made.map { identify($0, as: "close") }
        moreSlot.made.map { identify($0, as: "more") }
        pinSlot.made.map { identify($0, as: "pin") }
    }

    private func identify(_ button: NSView, as control: String) {
        guard let id = lastConfiguration?.0.id else { return }
        button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(id.rawValue).\(control)")
    }
}
