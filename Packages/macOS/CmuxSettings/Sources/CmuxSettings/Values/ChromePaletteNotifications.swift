import Foundation

public extension Notification.Name {
    /// Posted when the effective macOS light or dark appearance changes.
    static let systemAppearanceDidChange = Notification.Name("cmux.systemAppearanceDidChange")
}
