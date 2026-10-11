// App actions whose CLI verb belongs to the object's owner (SurfaceExemption
// .ownerVerb). The Rust CLI parses these words as daemon operations before
// its app fallback, so the app action could never run under that name;
// cli::tests::action_surface_parity fails when a new app cli_name collides.

nonisolated extension ActionSurfaceCatalog {
    /// `cmux room create` is the daemon's room.create (rooms are personal
    /// state the home session owns); the Rust CLI parses it before the
    /// app fallback; the app action space.new (Spaces, formerly Rooms) does the same job.
    /// The daemon owns layout and daemon browsers: `cmux workspace new|close`,
    /// `tab close`, `screen new|close`, `pane close` and `browser back|forward`
    /// are its operations and parse before the app fallback; an app
    /// browser tab's history runs as `cmux browser tab_… back|forward`.
    static let ownerVerbActions: [ActionID] = [
        "space.new", "newTab", "closeWorkspace", "closeTab", "screen.new", "screen.close", "closePane",
        "browserBack", "browserForward",
    ]
}
