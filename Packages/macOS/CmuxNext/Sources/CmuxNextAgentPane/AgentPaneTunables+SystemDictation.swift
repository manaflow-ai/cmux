public import CmuxNextDesign
import CmuxNextPages

nonisolated extension AgentPaneTunables {
    /// What the Dictation key (fn or the 🎤 key) and Edit ▸ Start Dictation do in an agent pane
    /// (``AgentPaneDictationKey``). Off (the default), they start the pane's own dictation, the
    /// waveform inside the composer, as its mic does. On, they start macOS's dictation, whose black
    /// overlay AppKit places at the web view's caret, over the composer's corner.
    public static let systemDictation = Tunable<Bool>.toggle(
        "agent.systemDictation", PageTunables.section, "Agent composer: macOS dictation",
        help: "The Dictation key and Edit ▸ Start Dictation in an agent pane start macOS's dictation and its overlay instead of cmux's dictation in the composer.",
        default: false, code: "AgentPaneTunables.systemDictation")
}
