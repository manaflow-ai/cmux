/// Whether post-replay restoration geometry is provisional or stable.
enum NotificationReplayRestoreContext {
    /// Boundary geometry may race a newer terminal row space before the first atomic restore.
    case provisional(NotificationScrollRestoreGeometry)
    /// Completed replay geometry retained for future notification activation.
    case stable(NotificationScrollRestoreGeometry)

    var geometry: NotificationScrollRestoreGeometry {
        switch self {
        case .provisional(let geometry), .stable(let geometry):
            geometry
        }
    }
}
