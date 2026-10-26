import Foundation

/// A memory source `optchat-chief memory import-from detect --json` found on this Mac.
struct MemorySource: Decodable, Equatable, Sendable {
    /// What the source is, for its title.
    enum Kind: String, Decodable, Sendable {
        case claudeCode = "claude-code"
        case claudeMemory = "claude-memory"
        case codex
        case chatgptExport = "chatgpt-export"
        case claudeAIExport = "claude-ai-export"
        case export
    }

    /// The `import-from` source name (`claude-code`, `zip:/path`).
    var source: String
    var kind: Kind
    /// Conversations (Claude Code), notes (the memory kinds) or 1 (an export zip).
    var count: Int
    var bytes: Int64
    var path: String

    private struct Found: Decodable { var sources: [MemorySource] }

    /// The sources in the CLI's answer; an answer that is not the CLI's JSON finds none. A source whose kind this
    /// app does not know is left out (a newer CLI may find more kinds).
    static func parse(_ data: Data) -> [MemorySource] {
        struct Lenient: Decodable {
            var sources: [Throwing]
            struct Throwing: Decodable {
                var value: MemorySource?
                init(from decoder: any Decoder) { value = try? MemorySource(from: decoder) }
            }
        }
        return (try? JSONDecoder().decode(Lenient.self, from: data))?.sources.compactMap(\.value) ?? []
    }

    /// The file name of an export zip.
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// The product the source belongs to, for the first-run offer ("Claude Code", "ChatGPT").
    var product: String {
        switch kind {
        case .claudeCode, .claudeMemory: ChiefMemoryImportStrings.productClaudeCode
        case .codex: ChiefMemoryImportStrings.productCodex
        case .chatgptExport: ChiefMemoryImportStrings.productChatGPT
        case .claudeAIExport: ChiefMemoryImportStrings.productClaudeAI
        case .export: ChiefMemoryImportStrings.productExport
        }
    }

    /// The row in the import dialog.
    var title: String {
        switch kind {
        case .claudeCode: ChiefMemoryImportStrings.claudeCode(count)
        case .claudeMemory: ChiefMemoryImportStrings.claudeMemory(count)
        case .codex: ChiefMemoryImportStrings.codex(count)
        case .chatgptExport: ChiefMemoryImportStrings.chatgptExport(fileName)
        case .claudeAIExport: ChiefMemoryImportStrings.claudeAIExport(fileName)
        case .export: ChiefMemoryImportStrings.exportZip(fileName)
        }
    }

    /// "Bring your memory from Claude Code and ChatGPT", or nil with nothing found. Products appear once, in
    /// the order found, joined the way the person's language joins a list.
    static func offerTitle(_ sources: [MemorySource], locale: Locale = .current) -> String? {
        var seen = Set<String>()
        let names = sources.map(\.product).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return nil }
        let list = ListFormatter()
        list.locale = locale
        return ChiefMemoryImportStrings.offer(list.string(from: names) ?? names.joined(separator: ", "))
    }
}

/// What `import-from SOURCE dry-run|write --json` answers.
struct MemoryImportReport: Decodable, Equatable, Sendable {
    struct Plan: Decodable, Equatable, Sendable {
        var total: Int
        var new: Int
        var duplicate: Int
        var secrets: Int
    }

    var plan: Plan
    var estCostUSD: Double
    /// Items written (a dry run writes none).
    var written: Int?
    var batch: String?

    enum CodingKeys: String, CodingKey { case plan, estCostUSD = "est_cost_usd", written, batch }

    static func parse(_ data: Data) -> MemoryImportReport? { try? JSONDecoder().decode(MemoryImportReport.self, from: data) }
}

/// The CLI arguments of one import: the same `optchat-chief memory import-from` the person can run by hand.
struct MemoryImportCommand: Equatable, Sendable {
    /// Where the memory goes.
    enum Target: Equatable, Sendable {
        /// This Mac's Chief (its host is stopped for the write, and starts again with the next message).
        case local(muxHome: String)
        /// A Cloud Chief; the session token is in a 0600 file.
        case cloud(chief: String, tokenFile: String)
    }

    var target: Target
    /// Most the estimated summary cost may be, in dollars; the CLI refuses above it.
    static let maxCostUSD = 20

    func detect() -> [String] { base(["detect", "--json"]) }

    func dryRun(_ source: String) -> [String] { base([source, "dry-run", "--json"] + targetArguments) }

    func write(_ source: String, batch: String) -> [String] {
        base([source, "write", "--json", "--batch", batch, "--max-cost", String(Self.maxCostUSD)] + targetArguments + stopHost)
    }

    func undo() -> [String] { base(["undo", "--json"] + targetArguments + stopHost) }

    private func base(_ rest: [String]) -> [String] {
        var arguments = ["memory", "import-from"]
        // The verbs come first, then the options (`--mux-home` first for a local Chief).
        arguments += rest
        if case .local(let home) = target { arguments += ["--mux-home", home] }
        return arguments
    }

    private var targetArguments: [String] {
        switch target {
        case .local: []
        case .cloud(let chief, let tokenFile): ["--to", "cloud", "--chief", chief, "--session-token-file", tokenFile]
        }
    }

    /// A local write stops the host (the memory has one writer); a cloud write needs nothing stopped.
    private var stopHost: [String] {
        if case .local = target { ["--stop-host"] } else { [] }
    }
}
