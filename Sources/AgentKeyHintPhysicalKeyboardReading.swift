import CmuxTerminalCore
import Foundation

/// Where ``AgentKeyHintPhysicalKeyboardStore`` reads the keyboard remaps
/// from: the live sources (``AgentKeyHintPhysicalKeyboardReader``), or a
/// fixture in tests.
protocol AgentKeyHintPhysicalKeyboardReading: Sendable {
    /// The stamp of `karabiner.json`. Cheap; called on the main thread at
    /// most every few seconds.
    func karabinerStamp() -> AgentKeyHintFileStamp

    /// Reads every source. May block; called on a background task.
    ///
    /// - Returns: The setup, and the `karabiner.json` stamp taken before it
    ///   was read, so a save during the read is noticed on the next check.
    func read() -> (setup: PhysicalKeyboardSetup, karabinerStamp: AgentKeyHintFileStamp)
}
