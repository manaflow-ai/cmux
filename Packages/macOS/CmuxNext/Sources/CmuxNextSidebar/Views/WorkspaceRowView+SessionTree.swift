import AppKit
import CmuxNextDesign

extension SidebarStyle {
    /// How far a workspace started by another's agent moves in under it (`sidebar.sessionTree`).
    static var treeIndent: CGFloat { Metrics.space4 }
}

// The session tree on a workspace row (`sidebar.sessionTree`, Claude desktop's Code tab): a started
// workspace's thin guide line and indent, the pull request badge, and the keycap of the first rows.
extension WorkspaceRowView {
    func setUpSessionTree() {
        treeLine.wantsLayer = true
        treeLine.isHidden = true
        treeFoldButton.isHidden = true
        treeFoldButton.onPress = { [weak self] in self?.onToggleTree?() }
    }

    func configureSessionTree(_ shown: WorkspaceRowContent) {
        treeDepth = shown.treeDepth
        treeLine.isHidden = shown.treeDepth == 0 || isShowingPlaceholder
        pullRequests.configure(isShowingPlaceholder ? nil : shown.pullRequests)
        keycap.configure(isShowingPlaceholder ? nil : shown.keycap)
        treeFold = isShowingPlaceholder ? nil : shown.treeFold
        treeFoldButton.icon = treeFold == .collapsed ? .disclosureCollapsed : .disclosureExpanded
        treeFoldButton.label = treeFold == .collapsed ? Strings.expandSessions : Strings.collapseSessions
        rollUp.configure(isShowingPlaceholder ? nil : shown.rollUp)
    }

    func tintSessionTree() {
        treeLine.layer?.backgroundColor = Palette.separator.cgColor
        pullRequests.tint()
        keycap.tint()
        rollUp.tint()
    }

    /// The guide line, in the indent a started workspace moves in by. It runs the row's full
    /// height and on into the spacing around it, so a parent's children read as one line.
    func layoutTreeLine(leading: CGFloat) {
        guard !treeLine.isHidden else { return }
        let width = max(1, Metrics.lineWidth(1)), reach = Metrics.space1
        treeLine.frame = NSRect(x: leading + Metrics.space2, y: -reach, width: width, height: bounds.height + 2 * reach)
    }

    /// A tree parent's chevron, right to left from `trailing`: always on a folded parent (its
    /// children are out of sight), on hover or selection on an open one, its slot kept either way.
    func layoutTreeFold(trailing: CGFloat, cy: CGFloat, control: CGFloat, fades: Bool) -> CGFloat {
        let shown = treeFold == .collapsed || (treeFold == .expanded && (revealsHoverControls || isSelected))
        setHoverShown(treeFoldButton, shown && !isShowingPlaceholder, fades: fades)
        guard treeFold != nil else { return trailing }
        treeFoldButton.frame = NSRect(x: trailing - control, y: cy - control / 2, width: control, height: control)
        return trailing - control - Metrics.space1
    }

    /// A folded parent's roll-up chips, right to left from `trailing`; the next trailing edge.
    func layoutRollUp(trailing: CGFloat, cy: CGFloat) -> CGFloat {
        guard !rollUp.isHidden else { return trailing }
        let size = rollUp.intrinsicContentSize
        rollUp.frame = NSRect(x: trailing - size.width, y: cy - size.height / 2, width: size.width, height: size.height)
        return trailing - size.width - Metrics.space2
    }

    /// The pull request badge, right to left from `trailing`; the next trailing edge.
    func layoutPullRequests(trailing: CGFloat, cy: CGFloat) -> CGFloat {
        guard !pullRequests.isHidden else { return trailing }
        let size = pullRequests.intrinsicContentSize
        pullRequests.frame = NSRect(x: trailing - size.width, y: cy - size.height / 2, width: size.width, height: size.height)
        return trailing - size.width - Metrics.space2
    }

    /// The keycap in the unread mark's slot (a row with an unread mark shows the mark); the slot's width.
    func layoutKeycap(trailing: CGFloat, cy: CGFloat, control: CGFloat) -> CGFloat {
        let size = keycap.intrinsicContentSize
        keycap.frame = NSRect(x: trailing - size.width, y: cy - size.height / 2, width: size.width, height: size.height)
        return max(control, size.width)
    }
}
