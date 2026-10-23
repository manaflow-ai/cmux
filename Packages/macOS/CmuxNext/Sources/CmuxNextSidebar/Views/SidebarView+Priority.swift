import AppKit
import CmuxNextDesign

/// The Priority view (`sidebar.priorityView.*`): while the App installs it, a bell in the titlebar
/// row, before the New Workspace button, and while the bell is on, the ranked agent chats at the
/// top of the sidebar, over the top band and the list. Uninstalled, the sidebar is unchanged.
extension SidebarViewComponents {
    /// The Priority view to draw, nil while it is not installed. The App ranks the rows.
    public func showPriority(_ panel: SidebarPriorityPanel?) {
        guard panel != priority else { return }
        let old = priority
        priority = panel
        priorityButton.isHidden = panel == nil
        priorityPanelView.isHidden = panel?.shown != true
        if let panel {
            // The label says what the dot means; the shortcut shows in the tooltip's own ink.
            let label = panel.shown ? Strings.priorityHide : Strings.priorityShow
            priorityButton.label = panel.bellDot ? label + ", " + Strings.priorityAttentionCount(panel.attentionCount) : label
            priorityButton.themedToolTipShortcut = panel.shortcut
            priorityButton.tintOverride = panel.shown ? Palette.notificationBlue : nil
            priorityBellDot.isHidden = !panel.bellDot
        }
        // Uninstalled, the view empties too, which stops its minute ticker.
        priorityPanelView.show(panel ?? SidebarPriorityPanel(entries: []))
        if old?.shown != panel?.shown || old == nil || panel == nil { needsLayout = true }
    }

    /// The person's choices in the Priority view and on its bell. Nil drops them.
    public var onPriorityAction: ((SidebarPriorityAction) -> Void)? {
        get { priorityPanelView.onAction }
        set { priorityPanelView.onAction = newValue }
    }

    func buildPriority() {
        priorityButton.isHidden = true
        priorityButton.setAccessibilityIdentifier("cmux.sidebar.priority")
        priorityButton.onPress = { [weak self] in self?.priorityPanelView.onAction?(.toggleShown) }
        priorityButton.wantsLayer = true
        priorityBellDot.isHidden = true
        priorityBellDot.backgroundColor = Palette.notificationBlue.cgColor
        priorityButton.layer?.addSublayer(priorityBellDot)
        addSubview(priorityButton)
        priorityPanelView.isHidden = true
        priorityPanelView.onHeightChange = { [weak self] in self?.needsLayout = true }
        addSubview(priorityPanelView)
    }

    /// Places the bell before `next` (the New Workspace button) in the titlebar row; returns the
    /// leftmost titlebar button's minX.
    func layoutPriorityButton(before next: NSRect) -> CGFloat {
        guard !priorityButton.isHidden else { return next.minX }
        priorityButton.frame = NSRect(x: next.minX - Metrics.space1 - next.width, y: next.minY, width: next.width, height: next.height)
        let dot = SidebarStyle.dotSize
        priorityBellDot.frame = CGRect(x: next.width * 0.62, y: next.height * 0.62 - dot, width: dot, height: dot)
        priorityBellDot.cornerRadius = dot / 2
        return priorityButton.frame.minX
    }

    /// Lays the Priority view out from `top` and returns the height it takes (0 while hidden). It
    /// takes at most two fifths of the sidebar and scrolls inside past that.
    func layoutPriority(top: CGFloat, width: CGFloat) -> CGFloat {
        guard !priorityPanelView.isHidden else { return 0 }
        let height = priorityPanelView.height(maximum: (bounds.height * 0.4).rounded())
        priorityPanelView.frame = NSRect(x: 0, y: top, width: width, height: height)
        return height
    }
}
