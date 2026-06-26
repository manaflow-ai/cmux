import AppKit
import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import Foundation

/// The runtime appearance/background-change notification dispatcher, drained out
/// of this app-target file into `CmuxTerminal` as
/// ``CmuxTerminal/TerminalDefaultBackgroundNotificationDispatcher``.
///
/// The alias keeps the legacy `GhosttyApp` construction and `signal(...)` call
/// sites byte-identical while the implementation, its coalescer, and the
/// appearance `userInfo` keys live in the package. The broadly-shared
/// `GhosttyNotificationKey` event vocabulary below stays here until its own
/// slice; its appearance-key raw values match the package's
/// ``CmuxTerminal/TerminalDefaultBackgroundUserInfoKey`` byte-for-byte, so a
/// payload built in the package is read here unchanged.
typealias GhosttyDefaultBackgroundNotificationDispatcher = TerminalDefaultBackgroundNotificationDispatcher

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let explicitFocusIntent = "ghostty.explicitFocusIntent"
    static let title = "ghostty.title"
    static let backgroundColor = "ghostty.backgroundColor"
    static let backgroundOpacity = "ghostty.backgroundOpacity"
    static let backgroundEventId = "ghostty.backgroundEventId"
    static let backgroundSource = "ghostty.backgroundSource"
    static let foregroundColor = "ghostty.foregroundColor"
    static let cursorColor = "ghostty.cursorColor"
    static let cursorTextColor = "ghostty.cursorTextColor"
    static let selectionBackground = "ghostty.selectionBackground"
    static let selectionForeground = "ghostty.selectionForeground"
}
