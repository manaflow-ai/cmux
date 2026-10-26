import CmuxNextWakeups

extension LaunchServicePosts {
    /// The service starts `AppServices.init` made in the launch turn, before the first frame
    /// (p08-startup-031; startup-DESIGN.md section 5, S6 to S10), one post each. The initializer only
    /// builds and wires; Chrome likewise builds its browser-wide services and posts their deferred
    /// starts (`AfterStartupTaskUtils::PostTask`, chrome/browser/after_startup_task_utils.cc).
    ///
    /// The window occlusion observer, input verification and notifications run after the first frame:
    /// none of them draws in it. The update sheet, server updates and the browser host provider run
    /// after startup; posted before the launch's `Updater.start`, the sheet is attached when the
    /// updater starts.
    ///
    /// - Parameters:
    ///   - windowOcclusion: Re-checks the surfaces after a window's occlusion changes.
    ///   - inputVerification: The input journal, the invariant monitor and the no-activate keyboard guard.
    ///   - notifications: Banners, rings, sounds and the Dock badge from the daemon's notifications.
    ///   - updateSheet: Wires the updater to the update sheet and the App.
    ///   - serverUpdates: Follows the daemon's handshakes for "Restart cmux-tui" notices and binds its action.
    ///   - browserHost: Builds and starts the browser host's engine provider.
    /// - Returns: The posts, the first three at afterFirstFrame and the rest at afterStartup.
    public static func serviceStarts(windowOcclusion: @escaping @MainActor @Sendable () -> Void,
                                     inputVerification: @escaping @MainActor @Sendable () -> Void,
                                     notifications: @escaping @MainActor @Sendable () -> Void,
                                     updateSheet: @escaping @MainActor @Sendable () -> Void,
                                     serverUpdates: @escaping @MainActor @Sendable () -> Void,
                                     browserHost: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "SurfaceInvariant.observeWindowOcclusion", work: windowOcclusion),
            Post(priority: .afterFirstFrame, name: "InputVerification.start", work: inputVerification),
            Post(priority: .afterFirstFrame, name: "Notifications.start", work: notifications),
            Post(priority: .afterStartup, name: "Updater.attach", work: updateSheet),
            Post(priority: .afterStartup, name: "ServerUpdates.start", work: serverUpdates),
            Post(priority: .afterStartup, name: "BrowserHost.start", work: browserHost),
        ])
    }
}
