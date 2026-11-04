/// What showing a window's workspace presents, decided from the window's facts with nothing shown.
/// The app's `WindowController.showWorkspace(requested:)` performs it, and a person's leave of a top
/// page asks it first: the page is left only for a workspace's panes, never for a waiting view, where
/// the key that asked would find no pane and be lost.
public enum WorkspacePresentation<Workspace> {
    /// The workspace's panes.
    case workspace(Workspace)
    /// Classic Home's page in place of the home workspace it stands for.
    case homePage(Workspace)
    /// The window's Cloud creation shows its progress.
    case creation
    /// The window's Cloud machine is still connecting: what shows stays.
    case waitingForMachine
    /// The window's Cloud machine is paused: its progress view.
    case pausedMachine
    /// The window asked for a workspace the store does not list yet: the connecting view.
    case awaitingWorkspace
    /// No workspace to show: the connecting view.
    case nothing

    /// The presentation shows a workspace's panes.
    public var showsPanes: Bool { if case .workspace = self { true } else { false } }

    /// The presentation for `requested`, in `showWorkspace`'s order: a creation; the requested workspace a
    /// machine holds; a remote machine that waits or is paused; a request a create still awaits; the first
    /// workspace the window lists; else nothing.
    public static func decide(requested: String?, creation: Bool, workspace: (String) -> Workspace?, homeStands: (Workspace) -> Bool,
                              onRemoteMachine: Bool, machineWaits: () -> Bool, machinePaused: () -> Bool,
                              awaits: (String) -> Bool, firstListed: () -> Workspace?) -> Self {
        if creation { return .creation }
        let shown = { (found: Workspace) in homeStands(found) ? Self.homePage(found) : .workspace(found) }
        if let requested, let found = workspace(requested) { return shown(found) }
        if requested != nil, onRemoteMachine, machineWaits() { return .waitingForMachine }
        if requested != nil, onRemoteMachine, machinePaused() { return .pausedMachine }
        if let requested, awaits(requested) { return .awaitingWorkspace }
        return firstListed().map(shown) ?? .nothing
    }
}
