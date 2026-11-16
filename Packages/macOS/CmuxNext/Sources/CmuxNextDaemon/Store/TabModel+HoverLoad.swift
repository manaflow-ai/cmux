extension TabModel {
    /// Whether a rest of the pointer on this tab may make its content before the click (hover load,
    /// `PaneController.loadOnHover`): a live terminal (its surface attaches, paused until shown), a browser
    /// page the app draws, or an agent chat. A dead terminal, an app tab and the other kinds wait for the click.
    public var loadsAheadOnHover: Bool {
        switch kind {
        case .pty: !dead
        case .browser: isFrontendOwned && appTab == nil
        case .conversation: agentSession != nil
        default: false
        }
    }
}
