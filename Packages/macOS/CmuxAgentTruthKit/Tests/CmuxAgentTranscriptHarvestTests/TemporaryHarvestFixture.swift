import Foundation

struct TemporaryHarvestFixture {
    let root: URL
    let claudeRoot: URL
    let codexRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxAgentTruthKitTests")
            .appendingPathComponent(UUID().uuidString)
        claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    func writeClaudeFile(named name: String, lines: [String]) throws {
        try writeFile(root: claudeRoot, named: name, lines: lines)
    }

    func writeCodexFile(named name: String, lines: [String]) throws {
        try writeFile(root: codexRoot, named: name, lines: lines)
    }

    private func writeFile(root: URL, named name: String, lines: [String]) throws {
        let url = root.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
