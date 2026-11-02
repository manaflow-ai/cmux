public import Foundation

/// A memory source `optchat-chief memory import-from detect --json` found on this Mac.
public struct MemorySource: Decodable, Equatable, Sendable {
    /// What the source is, for its title.
    public enum Kind: String, Decodable, Sendable {
        case claudeCode = "claude-code"
        case claudeMemory = "claude-memory"
        case codex
        case chatgptExport = "chatgpt-export"
        case claudeAIExport = "claude-ai-export"
        case export
    }

    /// The `import-from` source name (`claude-code`, `zip:/path`).
    public var source: String
    public var kind: Kind
    /// Conversations (Claude Code), notes (the memory kinds) or 1 (an export zip).
    public var count: Int
    public var bytes: Int64
    public var path: String

    private struct Found: Decodable { var sources: [MemorySource] }

    /// The sources in the CLI's answer; an answer that is not the CLI's JSON finds none. A source whose kind this
    /// app does not know is left out (a newer CLI may find more kinds).
    public static func parse(_ data: Data) -> [MemorySource] {
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
    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// The product the source belongs to, for the first-run offer ("Claude Code", "ChatGPT").
    public var product: String {
        switch kind {
        case .claudeCode, .claudeMemory: ChiefMemoryImportStrings.productClaudeCode
        case .codex: ChiefMemoryImportStrings.productCodex
        case .chatgptExport: ChiefMemoryImportStrings.productChatGPT
        case .claudeAIExport: ChiefMemoryImportStrings.productClaudeAI
        case .export: ChiefMemoryImportStrings.productExport
        }
    }

    /// The row in the import dialog.
    public var title: String {
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
    /// the order found, joined the way the person's language joins a list; three or more fit no row, so they read
    /// "Bring your memory from other AI tools" (the dialog names each).
    public static func offerTitle(_ sources: [MemorySource], locale: Locale = .current) -> String? {
        var seen = Set<String>()
        let names = sources.map(\.product).filter { seen.insert($0).inserted }
        guard !names.isEmpty else { return nil }
        if names.count > 2 { return ChiefMemoryImportStrings.offerMany }
        let list = ListFormatter()
        list.locale = locale
        return ChiefMemoryImportStrings.offer(list.string(from: names) ?? names.joined(separator: ", "))
    }
}

/// What `import-from SOURCE dry-run|write --json` answers.
public struct MemoryImportReport: Decodable, Equatable, Sendable {
    public struct Plan: Decodable, Equatable, Sendable {
        public var total: Int
        public var new: Int
        public var duplicate: Int
        public var secrets: Int

        public init(total: Int, new: Int, duplicate: Int, secrets: Int) {
            self.total = total
            self.new = new
            self.duplicate = duplicate
            self.secrets = secrets
        }
    }

    public var plan: Plan
    public var estCostUSD: Double
    /// Items written (a dry run writes none).
    public var written: Int?
    public var batch: String?

    enum CodingKeys: String, CodingKey { case plan, estCostUSD = "est_cost_usd", written, batch }

    public static func parse(_ data: Data) -> MemoryImportReport? { try? JSONDecoder().decode(MemoryImportReport.self, from: data) }
}

/// The CLI arguments of one import: the same `optchat-chief memory import-from` the person can run by hand.
public struct MemoryImportCommand: Equatable, Sendable {
    /// Where the memory goes.
    public enum Target: Equatable, Sendable {
        /// This Mac's Chief (its host is stopped for the write, and starts again with the next message).
        case local(muxHome: String)
        /// A Cloud Chief; the session token is in a 0600 file.
        case cloud(chief: String, tokenFile: String)
    }

    public var target: Target
    /// Most the estimated summary cost may be, in dollars; the CLI refuses above it.
    public static let maxCostUSD = 20

    public init(target: Target) { self.target = target }

    /// The arguments that list the memory sources on this Mac.
    ///
    /// - Parameter exports: also list claude.ai and ChatGPT export zips in `~/Downloads` and `~/Desktop`.
    ///   macOS guards those folders and asks the person for access the first time cmux reads them, so pass
    ///   `true` only for the person's own request (the Import Memories dialog), never for a launch-time
    ///   offer (LAUNCH-NO-TCC-PROMPTS).
    public func detect(exports: Bool = false) -> [String] { base(["detect", "--json"] + (exports ? ["--exports"] : [])) }

    public func dryRun(_ source: String) -> [String] { base([source, "dry-run", "--json"] + targetArguments) }

    public func write(_ source: String, batch: String) -> [String] {
        base([source, "write", "--json", "--batch", batch, "--max-cost", String(Self.maxCostUSD)] + targetArguments + stopHost)
    }

    public func undo() -> [String] { base(["undo", "--json"] + targetArguments + stopHost) }

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
