#if canImport(UIKit)
import Foundation

/// Notification names emitted by the mobile terminal runtime.
public extension Notification.Name {
    /// Posted when the embedded mobile terminal should adopt a new color theme.
    static let cmuxMobileTerminalThemeDidChange = Notification.Name("cmuxMobileTerminalThemeDidChange")
}

/// User-info key whose value is the new ``TerminalTheme`` for a mobile terminal theme notification.
public let cmuxMobileTerminalThemeNotificationThemeKey = "theme"

#endif
