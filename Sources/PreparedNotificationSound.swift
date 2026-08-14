/// A fully prepared notification sound that no longer requires file-system work.
enum PreparedNotificationSound: Equatable, Sendable {
    case systemDefault
    case silent
    case named(String)
}
