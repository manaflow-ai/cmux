import Foundation

public final class AgentPaneDraftTexts: @unchecked Sendable {
    public static let fileName = "agent-composer-drafts.json"
    public static var shared: AgentPaneDraftTexts?
    private let file: URL?
    private let lock = NSLock()
    private var drafts: [String: String]

    public init(directory: URL?) {
        file = directory?.appending(path: Self.fileName)
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) { drafts = decoded }
        else { drafts = [:] }
    }
    public func get(_ sessionId: String) -> String? { lock.lock(); defer { lock.unlock() }; return drafts[sessionId] }
    public func set(_ text: String, for sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        if drafts[sessionId] == value { return }
        drafts[sessionId] = value
        guard let file else { return }
        do {
            if drafts.isEmpty { try FileManager.default.removeItem(at: file) }
            else {
                let parent = file.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(drafts).write(to: file, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch { }
    }
}
