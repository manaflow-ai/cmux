import CmuxNextWakeups

extension LaunchServicePosts {
    /// The service starts `AppServices.init` made in the launch turn, before the first frame
    /// (startup-DESIGN.md section 5, S6 to S10), one post each. The initializer only
    /// builds and wires (closures, action bindings, NSApp input hooks); Chrome likewise builds its
    /// browser-wide services and posts their deferred starts (`AfterStartupTaskUtils::PostTask`,
    /// chrome/browser/after_startup_task_utils.cc).
    ///
    /// The window occlusion observer, input verification and notifications run after the first frame:
    /// none of them draws in it. The updater's reads behind its wired cards, server updates and the
    /// browser host provider run after startup.
    ///
    /// - Parameters:
    ///   - windowOcclusion: Re-checks the surfaces after a window's occlusion changes.
    ///   - inputVerification: The input journal and the invariant monitor with its triggers.
    ///   - notifications: Banners, rings, sounds and the Dock badge from the daemon's notifications.
    ///   - updaterWork: The updater's work behind the cards `init` wired: this build's notes, the tip's re-pick.
    ///   - serverUpdates: Follows the daemon's handshakes for "Restart cmux-tui" notices.
    ///   - browserHost: Builds and starts the browser host's engine provider.
    /// - Returns: The posts, the first three at afterFirstFrame and the rest at afterStartup.
    public static func serviceStarts(windowOcclusion: @escaping @MainActor @Sendable () -> Void,
                                     inputVerification: @escaping @MainActor @Sendable () -> Void,
                                     notifications: @escaping @MainActor @Sendable () -> Void,
                                     updaterWork: @escaping @MainActor @Sendable () -> Void,
                                     serverUpdates: @escaping @MainActor @Sendable () -> Void,
                                     browserHost: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "SurfaceInvariant.observeWindowOcclusion", work: windowOcclusion),
            Post(priority: .afterFirstFrame, name: "InputVerification.start", work: inputVerification),
            Post(priority: .afterFirstFrame, name: "Notifications.start", work: notifications),
            Post(priority: .afterStartup, name: "Updater.attachedWork", work: updaterWork),
            Post(priority: .afterStartup, name: "ServerUpdates.start", work: serverUpdates),
            Post(priority: .afterStartup, name: "BrowserHost.start", work: browserHost),
        ])
    }
}
