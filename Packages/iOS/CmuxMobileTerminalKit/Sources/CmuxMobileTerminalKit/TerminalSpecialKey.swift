import Foundation

/// Platform-neutral identifier for the non-character keys the terminal input
/// pipeline encodes (arrows, navigation, control keys).
///
/// The UI host maps `UIKeyCommand.input*` constants onto these cases so the
/// byte-encoding in ``TerminalKeyEncoder`` stays free of UIKit and testable
/// on any platform.
///
/// `Codable` (synthesized by case name) lets a ``CustomToolbarAction`` that
/// sends a special key persist which key it targets.
public enum TerminalSpecialKey: Hashable, Sendable, Codable {
    /// The Up arrow key.
    case upArrow
    /// The Down arrow key.
    case downArrow
    /// The Left arrow key.
    case leftArrow
    /// The Right arrow key.
    case rightArrow
    /// The Home key.
    case home
    /// The End key.
    case end
    /// The Page Up key.
    case pageUp
    /// The Page Down key.
    case pageDown
    /// The forward Delete key.
    case delete
    /// The Escape key.
    case escape
    /// The Tab key.
    case tab
}
