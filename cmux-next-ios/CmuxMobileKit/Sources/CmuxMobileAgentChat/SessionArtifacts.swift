import CmuxMobileArtifacts
import Foundation

/// Every file, folder, link and image an agent session referenced, in any
/// form: tool-call locations, edits and their diffs, paths and URLs in tool
/// input and shell output, images in tool output, the person's attachments,
/// links and paths in prompts and answers, and the same inside subagents.
/// Items with data already in the session (attachments, images) are served
/// inline, attachments kept on disk from the phone's file; the rest load from
/// `fallback` (the Mac's `file` service, or mock).
public struct SessionArtifacts: Sendable {
    public var artifacts: [TerminalArtifact]
    public var inline: [String: ArtifactContent]
    /// Attachments held by URL, not bytes (a large picked or pasted file), by reference.
    public var onDisk: [String: LocalFile]

    public init(artifacts: [TerminalArtifact], inline: [String: ArtifactContent], onDisk: [String: LocalFile] = [:]) {
        self.artifacts = artifacts
        self.inline = inline
        self.onDisk = onDisk
    }

    public func source(fallback: any ArtifactSource) -> any ArtifactSource {
        let files = onDisk.isEmpty ? fallback : OnDiskAttachmentSource(files: onDisk, fallback: fallback)
        return InlineArtifactSource(inline: inline, fallback: files)
    }

    /// Serves `onDisk` attachments by their `Attachments/` reference through
    /// `LocalFileArtifactSource`, which opens the file's scope and holds it
    /// while this source (the open browser) lives.
    struct OnDiskAttachmentSource: ArtifactSource {
        let files: [String: LocalFile]
        let local: LocalFileArtifactSource

        init(files: [String: LocalFile], fallback: any ArtifactSource) {
            self.files = files
            local = LocalFileArtifactSource(files: Array(files.values), fallback: fallback)
        }

        func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent {
            guard let file = files[artifact.reference] else { return try await local.load(artifact) }
            var own = file.artifact
            own.kind = artifact.kind
            return try await local.load(own)
        }
    }

    /// How strongly a reference was tied to the session (a later, stronger mention wins the label).
    enum Weight: Int, Comparable {
        case mentioned, linked, output, searched, read, attached, edited
        static func < (lhs: Weight, rhs: Weight) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static func collect(turns: [AgentTurn], subagents: [AgentSubagent], cwd: String) -> SessionArtifacts {
        var collector = Collector(cwd: cwd)
        for turn in turns {
            collector.scanText(turn.prompt, detail: "In your prompt", weight: .mentioned)
            for attachment in turn.attachments { collector.add(attachment) }
            collector.scan(turn.items, subagents: subagents)
        }
        for agent in subagents {
            collector.scanText(agent.task ?? "", detail: "In \(agent.name)'s task", weight: .mentioned)
        }
        return collector.result
    }

    struct Collector {
        let cwd: String
        var entries: [String: (artifact: TerminalArtifact, weight: Weight)] = [:]
        var inline: [String: ArtifactContent] = [:]
        var onDisk: [String: LocalFile] = [:]
        var count = 0

        /// Relevance order (the browser lists the highest `order` first):
        /// files the agent edited or created and your attachments, then files
        /// it read, then other files it touched or named, then links. Newest
        /// first within each tier.
        var result: SessionArtifacts {
            let ranked = entries.values.sorted { lhs, rhs in
                let (a, b) = (Self.tier(lhs.artifact, lhs.weight), Self.tier(rhs.artifact, rhs.weight))
                return a != b ? a < b : lhs.artifact.order > rhs.artifact.order
            }
            let artifacts = ranked.enumerated().map { index, entry in
                var artifact = entry.artifact
                artifact.order = ranked.count - 1 - index
                return artifact
            }
            return SessionArtifacts(artifacts: artifacts, inline: inline, onDisk: onDisk)
        }

        static func tier(_ artifact: TerminalArtifact, _ weight: Weight) -> Int {
            if artifact.kind == .link { return 3 }
            switch weight {
            case .edited, .attached: return 0
            case .read: return 1
            case .searched, .output, .linked, .mentioned: return 2
            }
        }

        /// Paths inside the session's folder show relative to it.
        func normalize(_ reference: String) -> String {
            var reference = reference
            if cwd.hasPrefix("/"), reference.hasPrefix(cwd + "/") { reference = String(reference.dropFirst(cwd.count + 1)) }
            // A display folder (`~/x`): an absolute path under any home's `x` is the same file.
            if cwd.hasPrefix("~/"), reference.hasPrefix("/"), let range = reference.range(of: String(cwd.dropFirst()) + "/") {
                let home = reference[..<range.lowerBound].split(separator: "/")
                if home.count == 2, ["Users", "home"].contains(home[0]) { reference = String(reference[range.upperBound...]) }
            }
            if reference.hasPrefix("./") { reference = String(reference.dropFirst(2)) }
            return reference
        }

        /// `replacesKind`: a newer attachment of the same name, whose kind wins at an equal weight.
        mutating func add(_ reference: String, kind: TerminalArtifact.Kind? = nil, line: Int? = nil, detail: String, weight: Weight,
                          replacesKind: Bool = false) {
            let reference = kind == .link ? reference : normalize(reference)
            guard !reference.isEmpty, let kind = kind ?? Self.kind(of: reference) else { return }
            if let existing = entries[reference] {
                guard weight > existing.weight || (replacesKind && weight == existing.weight) else { return }
                var artifact = existing.artifact
                if replacesKind { artifact.kind = kind }
                artifact.detail = detail
                artifact.line = artifact.line ?? line
                entries[reference] = (artifact, weight)
                return
            }
            entries[reference] = (TerminalArtifact(reference: reference, kind: kind, line: line, order: count, detail: detail), weight)
            count += 1
        }

        static func kind(of path: String) -> TerminalArtifact.Kind? {
            let name = (path as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let kind = TerminalArtifact.kind(forExtension: ext) { return kind }
            if path.hasSuffix("/") { return .directory }
            return ArtifactExtractor.classify(path) ?? (ext.isEmpty ? nil : .text)
        }

        mutating func add(_ attachment: AgentAttachment) {
            let reference = "Attachments/\(attachment.name)"
            let key = normalize(reference)
            // The newest attachment of a name is the one that opens: its bytes or its file, never an older one's.
            if attachment.data != nil {
                onDisk[key] = nil
            } else if attachment.fileURL != nil {
                inline[key] = nil
                // Too large to hold: the phone's file, never the Mac's (it has no `Attachments/`).
                onDisk[key] = attachment.localFile
            }
            switch attachment.kind {
            case .image:
                add(reference, kind: .image, detail: "Attached", weight: .attached, replacesKind: true)
                if let data = attachment.data { inline[key] = .image(data) }
            case .file:
                let kind = Self.kind(of: attachment.name) ?? .binary
                add(reference, kind: kind, detail: "Attached", weight: .attached, replacesKind: true)
                if let data = attachment.data {
                    inline[key] = (try? LinkFileArtifactSource.content(
                        for: TerminalArtifact(reference: reference, kind: kind), data: data)) ?? .binary(description: attachment.name)
                }
            }
        }

        /// Paths and URLs in free text (prompts, answers, shell output). Markdown link targets count too.
        mutating func scanText(_ text: String, detail: String, weight: Weight) {
            guard !text.isEmpty else { return }
            var extractor = ArtifactExtractor()
            let unwrapped = text.replacingOccurrences(of: #"\]\(([^)\s]+)\)"#, with: "] $1 ", options: .regularExpression)
            for line in unwrapped.components(separatedBy: .newlines) {
                for found in extractor.scanLine(line) {
                    add(found.reference, kind: found.kind, line: found.line, detail: detail, weight: weight)
                }
            }
        }

        mutating func scan(_ items: [TurnItem], subagents: [AgentSubagent], owner: String? = nil) {
            let suffix = owner.map { " · \($0)" } ?? ""
            for item in items {
                switch item {
                case .message(_, let markdown):
                    scanText(markdown, detail: "In the answer" + suffix, weight: .linked)
                case .tool(let call):
                    scan(call, suffix: suffix)
                case .plan(_, let entries):
                    for entry in entries { scanText(entry.content, detail: "In the plan" + suffix, weight: .mentioned) }
                case .permission(let record):
                    scan(record.request.toolCall, suffix: suffix)
                case .subagents(_, let ids):
                    for id in ids {
                        guard let agent = subagents.first(where: { $0.id == id }) else { continue }
                        scan(agent.items, subagents: subagents, owner: agent.name)
                    }
                case .thought, .question:
                    break
                }
            }
        }

        mutating func scan(_ call: ACPToolCall, suffix: String) {
            let (verb, weight): (String, Weight) = switch call.kind {
            case .read: ("Read", .read)
            case .edit, .fileChange: ("Edited", .edited)
            case .delete: ("Deleted", .edited)
            case .move: ("Moved", .edited)
            case .search: ("Searched", .searched)
            case .fetch: ("Fetched", .read)
            default: ("Used", .output)
            }
            for diff in call.diffs {
                let added = diff.newText.split(separator: "\n", omittingEmptySubsequences: false).count
                let label = diff.oldText == nil ? "Created · \(added) lines" : "Edited"
                add(diff.path, line: nil, detail: label + suffix, weight: .edited)
            }
            for location in call.locations {
                add(location.path, line: location.line, detail: verb + suffix, weight: weight)
            }
            // Paths and URLs named in the input (file_path, path, url, command).
            if case .object(let input)? = call.rawInput {
                for key in ["file_path", "filePath", "path", "notebook_path"] {
                    if let path = input[key]?.stringValue { add(path, detail: verb + suffix, weight: weight) }
                }
                if let url = input["url"]?.stringValue { add(url, kind: .link, detail: "Fetched" + suffix, weight: .read) }
            }
            if let command = call.command { scanText(command, detail: "In a command" + suffix, weight: .mentioned) }
            var images = 0
            for content in call.content {
                guard case .content(let block) = content else { continue }
                switch block {
                case .text(let text):
                    let detail = call.kind == .execute ? "Command output" : "In \(verb.lowercased()) output"
                    scanText(text, detail: detail + suffix, weight: .output)
                case .image(let mimeType, let data):
                    images += 1
                    let ext = mimeType.split(separator: "/").last.map(String.init) ?? "png"
                    let reference = "Tool output/\(call.title.isEmpty ? "image" : call.title) \(images).\(ext)"
                    add(reference, kind: .image, detail: "Image from \(call.title)" + suffix, weight: .output)
                    if let bytes = Data(base64Encoded: data) { inline[normalize(reference)] = .image(bytes) }
                case .resourceLink(let uri, _):
                    if uri.hasPrefix("http") {
                        add(uri, kind: .link, detail: "Linked by \(call.title)" + suffix, weight: .linked)
                    } else {
                        let path = uri.hasPrefix("file://") ? (URL(string: uri)?.path ?? uri) : uri
                        add(path, detail: "Linked by \(call.title)" + suffix, weight: .linked)
                    }
                }
            }
        }
    }
}
