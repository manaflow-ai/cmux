/// The terminal dictation would insert into, plus whether it is running a
/// coding agent (which turns on filler cleanup).
struct VoiceDictationTerminalTarget {
    let panel: TerminalPanel
    let isAgentPrompt: Bool
}
