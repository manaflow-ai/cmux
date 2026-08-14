import Foundation

public extension Notification.Name {
    /// Posted when the authoritative app-wide chrome palette changes.
    static let cmuxChromePaletteDidChange = Notification.Name("cmux.chromePaletteDidChange")

    /// Posted when the effective macOS light or dark appearance changes.
    static let systemAppearanceDidChange = Notification.Name("cmux.systemAppearanceDidChange")
}
