public import GhosttyKit

/// A named-key press queued while the runtime surface does not exist yet.
///
/// Socket-driven named keys (arrows, escape, enter) sent to a cold surface
/// are queued as key events and replayed once the runtime surface starts.
public struct PendingKeyEvent: Sendable {
    /// The macOS virtual key code to replay.
    public let keycode: UInt32

    /// The ghostty modifier bits active for the key press.
    public let mods: ghostty_input_mods_e

    /// The human-readable key label, used for queue accounting.
    public let label: String

    /// Creates a queued named-key press.
    ///
    /// - Parameters:
    ///   - keycode: The macOS virtual key code to replay.
    ///   - mods: The ghostty modifier bits active for the key press.
    ///   - label: The human-readable key label.
    public init(keycode: UInt32, mods: ghostty_input_mods_e, label: String) {
        self.keycode = keycode
        self.mods = mods
        self.label = label
    }

    /// The byte cost this event contributes to the pending-input budget.
    public var queuedByteCost: Int {
        max(label.utf8.count, 1)
    }
}
