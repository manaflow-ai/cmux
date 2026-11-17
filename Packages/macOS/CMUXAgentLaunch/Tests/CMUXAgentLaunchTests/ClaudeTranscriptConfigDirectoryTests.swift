import CMUXAgentLaunch
import Testing

@Suite("ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath:)")
struct ClaudeTranscriptConfigDirectoryTests {
    @Test("Returns the config directory above a session transcript")
    func sessionTranscript() {
        #expect(
            ClaudeConfigDirectoryPath.configDirectory(
                ofTranscriptPath: "/Users/a/.codex-accounts/claude/work/projects/-Users-a-repo/0f1e.jsonl"
            ) == "/Users/a/.codex-accounts/claude/work"
        )
    }

    @Test("Returns the config directory above a nested subagent transcript")
    func subagentTranscript() {
        #expect(
            ClaudeConfigDirectoryPath.configDirectory(
                ofTranscriptPath: "/Users/a/.claude/projects/-Users-a-repo/0f1e/subagents/agent-1.jsonl"
            ) == "/Users/a/.claude"
        )
    }

    @Test("Uses the last projects component when the config dir sits under a projects folder")
    func configDirectoryUnderProjectsFolder() {
        #expect(
            ClaudeConfigDirectoryPath.configDirectory(
                ofTranscriptPath: "/Users/a/projects/claude-config/projects/-Users-a-repo/0f1e.jsonl"
            ) == "/Users/a/projects/claude-config"
        )
    }

    @Test("Returns nil for paths that do not name a transcript below a project directory")
    func rejectsNonTranscriptPaths() {
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: nil) == nil)
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: "  ") == nil)
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: "projects/-repo/0f1e.jsonl") == nil)
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: "/Users/a/.claude/projects/0f1e.jsonl") == nil)
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: "/projects/-repo/0f1e.jsonl") == nil)
        #expect(ClaudeConfigDirectoryPath.configDirectory(ofTranscriptPath: "/Users/a/.claude/projects/-repo/notes.txt") == nil)
    }
}
