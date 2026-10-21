import CmuxNextDaemon

/// The notification a finished `cmux status run` posts on its terminal's tab.
struct StatusRunNotice: Hashable {
    var title: String
    var body: String
    var level: NotificationLevel
    /// The run's terminal tab, nil when it is not in this client's store.
    var surface: SurfaceID?
}
