public import Foundation

/// The chats cmux can resume: Claude Code and Codex sessions, the two
/// harnesses acpmux adopts. Uses the project scan's locations and folder
/// rules, so a chat shows only under a project the projects step would list.
///
/// - Claude Code: a file named by a UUID is a session, and the name is its id
///   (`agent-*.jsonl` files are subagent transcripts, which can't be resumed).
///   Prompts are `user` records with text that isn't a tool result, a meta,
///   sidechain or compact-summary record, or injected `<...>` context. The
///   first prompt names the chat: a `summary` record may describe another
///   session, so it is not used.
/// - Codex: `session_meta.payload.id` is the session id; prompts are
///   `event_msg` `user_message` records, else `response_item` user messages.
public nonisolated struct AgentChatScan: Sendable {
    public var projects: AgentProjectScan
    /// The newest chats returned; older ones add nothing a user would pick.
    public var limit = 60
    /// Bytes read per session file; a longer chat's count stops there.
    public var bytesPerFile = 32 * 1024 * 1024

    public init(projects: AgentProjectScan) {
        self.projects = projects
    }

    /// The chats, newest first.
    public func run() -> [AgentChat] {
        let claude = AgentProjectScan.files(in: projects.claude.appending(path: "projects"), depth: 1, ext: "jsonl")
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { (AgentApp.claudeCode, $0) }
        let codex = AgentProjectScan.files(in: projects.codex.appending(path: "sessions"), depth: 3, ext: "jsonl")
            .filter { $0.lastPathComponent.hasPrefix("rollout-") }
            .map { (AgentApp.codex, $0) }
        let dated = (claude + codex).map { ($0.0, $0.1, AgentProjectScan.modified($0.1)) }.sorted { $0.2 > $1.2 }
        var chats: [AgentChat] = []
        for (app, file, modified) in dated where chats.count < limit {
            if let chat = read(app, file, modified: modified), projects.keeps(folder: chat.folder) {
                chats.append(chat)
            }
        }
        return chats
    }

    func read(_ app: AgentApp, _ file: URL, modified: Date) -> AgentChat? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytesPerFile) else { return nil }
        var reader = ChatRecordReader(app: app)
        if app == .claudeCode { reader.sessionID = file.deletingPathExtension().lastPathComponent }
        let needles = Self.needles(app)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Most lines are tool output and replies; only parse ones that can matter.
            guard needles.contains(where: { line.range(of: $0) != nil }),
                  let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            reader.add(record)
        }
        guard let id = reader.sessionID, let cwd = reader.cwd, reader.prompts > 0 else { return nil }
        return AgentChat(sessionID: id, app: app, folder: URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL,
                         title: reader.firstPrompt ?? "", prompts: reader.prompts, lastActive: modified)
    }

    /// Byte strings at least one of which every record `ChatRecordReader` uses contains.
    static func needles(_ app: AgentApp) -> [Data] {
        let strings = app == .codex ? [#""session_meta""#, #""user_message""#, #""role":"user""#]
            : [#""type":"user""#]
        return strings.map { Data($0.utf8) }
    }
}
