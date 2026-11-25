public import CmuxNextLayout

// The Chief panel (user 2026-11-06): the Chief chat floating over the workspace a window shows, or docked at one
// edge as a Chief-only pane, never over Home. It opens only on purpose: a link clicked in the Chief (the next
// workspace that link shows gets it, floating), or Show/Hide Chief (Cmd-I). A workspace opened any other way (the
// sidebar, Cmd-P, a switch, a restore, a launch, a new window) shows no Chief. Docking is the person's choice (Dock
// in its bar, or Dock Workspace on Home); Float floats it again. Every entry point ends in one of these operations,
// which change window view state in this turn.
public extension WindowDockFrame {
    /// How long a link from the Chief may take to show its workspace and still open the panel over it: a subagent
    /// link may first make its workspace (one daemon round trip).
    static var chiefPanelLinkWindow: Duration { .seconds(10) }

    /// A link in the Chief (the open-workspace indicator) is about to open from Home: the next workspace this
    /// window shows gets the floating Chief. Nothing while the window shows something else; an open that shows
    /// nothing else in this window leaves the arm to lapse.
    func armChiefPanel(now: ContinuousClock.Instant = .now) {
        guard let home = frameHome, frameShownWorkspaceID == home else { return }
        frameChiefPanelArm = now.advanced(by: Self.chiefPanelLinkWindow)
    }

    /// A show of `target` is about to replace the shown workspace: an armed link opens the panel floating over it,
    /// also when the person docked it before (cmux#37372: no link click docks the Chief). Any show of another
    /// workspace takes the arm, used or not.
    func openChiefPanelOnLeave(for target: String, now: ContinuousClock.Instant = .now) {
        guard let until = frameChiefPanelArm, target != frameHome else { return }
        frameChiefPanelArm = nil
        guard now < until else { return }
        frameChiefPanel.openFloating()
        frameSaveRecord()
    }

    /// Show/Hide Chief (Cmd-I): hides the panel when it shows; else opens it the way it was (floating, or docked
    /// when the person docked it) and gives it the keys. False when it cannot show: no Home, or the window shows
    /// Home, where the Chief already is.
    @discardableResult
    func toggleChiefPanel() -> Bool {
        if frameChiefPanelShown {
            hideChiefPanel()
            return true
        }
        guard let home = frameHome, let stage = chiefPanelStage, stage != home else { return false }
        frameChiefPanel.open()
        frameChiefPanelDidChange()
        frameFocusChiefPanel()
        return true
    }

    /// Hides the panel, keeping its placement; the stage takes the keys when the panel had them.
    func hideChiefPanel() {
        let hadKeys = frameChiefPanelHasKeys
        frameChiefPanel.hide()
        frameChiefPanelDidChange()
        if hadKeys { frameFocusStage(toward: nil) }
    }

    /// Docks the panel at `edge` and opens it: a Chief-only pane beside every workspace but Home.
    func dockChiefPanel(at edge: DockEdge) {
        frameChiefPanel.dock(at: edge)
        frameChiefPanelDidChange()
    }

    /// Floats a docked panel again at its floating place; false when it was not docked.
    @discardableResult
    func floatChiefPanel() -> Bool {
        guard frameChiefPanel.undock() else { return false }
        frameChiefPanelDidChange()
        return true
    }

    /// Undock Chief (cmux#37372): a docked panel floats again and shows, also when the person had hidden it, so
    /// the action always has a visible result. False when it was not docked.
    @discardableResult
    func undockChiefPanel() -> Bool {
        guard frameChiefPanel.dockedEdge != nil else { return false }
        frameChiefPanel.openFloating()
        frameChiefPanelDidChange()
        return true
    }

    /// The panel's Dock/Float button: Float when docked, else Dock at `edge`.
    func toggleChiefPanelDock(edge: DockEdge) {
        if !floatChiefPanel() { dockChiefPanel(at: edge) }
    }

    /// A pane focus move (Cmd-Ctrl-H/J/K/L, Cmd-Option-arrows) while the panel has the keys: back to the stage's
    /// pane nearest the panel, in any direction but into the window's edge from a docked panel (where it stays).
    /// False when the panel did not have the keys (the move is the stage's).
    func moveFocusFromChiefPanel(toward direction: LayoutDirection) -> Bool {
        guard frameChiefPanelHasKeys else { return false }
        let edge = frameChiefPanel.dockedEdge
        let intoEdge = edge.map { [DockEdge.left: LayoutDirection.left, .right: .right, .top: .up, .bottom: .down][$0] == direction } ?? false
        if !intoEdge { frameFocusStage(toward: direction) }
        return true
    }

    /// A pane focus move with no pane that way in the stage: the panel takes the keys when it lies that way. True
    /// when it did.
    func moveFocusIntoChiefPanel(toward direction: LayoutDirection) -> Bool {
        guard frameChiefPanelShown, frameChiefPanelLies(toward: direction) else { return false }
        frameFocusChiefPanel()
        return true
    }

    /// The workspace the stage shows now: the shown one unless a dock holds it.
    var chiefPanelStage: String? {
        guard let shown = frameShownWorkspaceID else { return nil }
        return frameDocks.isDocked(shown) ? frameStageWorkspaceID ?? shown : shown
    }

    /// Whether the panel draws in this arrangement: open, over a stage that is not Home.
    var chiefPanelBelongsOnScreen: Bool { frameChiefPanel.isShown(stage: chiefPanelStage, home: frameHome) }
}
