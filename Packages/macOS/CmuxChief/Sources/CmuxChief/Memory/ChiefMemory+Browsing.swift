public import Foundation

/// One of the two Markdown files the user edits (person.md, instructions.md).
public enum ChiefMemoryDocument: String, CaseIterable, Sendable {
    /// person.md, the user's profile ("About You").
    case person
    /// instructions.md, the user's rules for Chief.
    case instructions

    /// The document's file inside `paths`.
    public func url(in paths: ChiefMemoryPaths) -> URL {
        switch self {
        case .person: paths.person
        case .instructions: paths.instructions
        }
    }
}

/// What the memory browser reads and writes besides `add`/`forget`: the
/// documents' raw text, an atomic save, the newest facts, and which facts a
/// change added (the transcript's "Chief will remember" row).
extension ChiefMemory {
    /// The document's raw text (comments included); empty when the file is missing or unreadable.
    public func text(of document: ChiefMemoryDocument) -> String {
        (try? String(contentsOf: document.url(in: paths), encoding: .utf8)) ?? ""
    }

    /// When the document was last written; nil when it is missing.
    public func modificationDate(of document: ChiefMemoryDocument) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: document.url(in: paths).path)
        return attributes?[.modificationDate] as? Date
    }

    /// Replaces the document with `text`: written to a temporary sibling and
    /// renamed over it, so a reader (the CLI, the next session) never sees a
    /// half-written file. The file stays private (0600).
    ///
    /// - Throws: ``ChiefMemoryError/io(_:)`` when a file system call fails.
    public func save(_ text: String, to document: ChiefMemoryDocument) throws {
        let target = document.url(in: paths)
        do {
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let temporary = paths.directory.appendingPathComponent(".\(target.lastPathComponent).\(getpid()).tmp")
            try Data(text.utf8).write(to: temporary, options: [])
            _ = chmod(temporary.path, 0o600)
            guard rename(temporary.path, target.path) == 0 else {
                let reason = String(cString: strerror(errno))
                try? FileManager.default.removeItem(at: temporary)
                throw ChiefMemoryError.io("rename: \(reason)")
            }
        } catch let error as ChiefMemoryError {
            throw error
        } catch {
            throw ChiefMemoryError.io("\(error)")
        }
    }

    /// The newest `limit` facts, newest first.
    public func recentFacts(limit: Int) -> [ChiefMemoryFact] {
        Array(facts().reversed().prefix(max(0, limit)))
    }

    /// The facts in `new` whose ids `old` lacks, in `new`'s order (oldest first).
    /// A forget (a fact gone) adds nothing.
    public static func addedFacts(from old: [ChiefMemoryFact], to new: [ChiefMemoryFact]) -> [ChiefMemoryFact] {
        let known = Set(old.map(\.id))
        return new.filter { !known.contains($0.id) }
    }
}
