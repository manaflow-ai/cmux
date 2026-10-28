import CmuxNextCompat
import Foundation

/// The layout templates of this Mac, in one JSON file of this build's support folder
/// (`layout-templates.json` beside the sidebar snapshot); the file is the source of truth and
/// every change rewrites it atomically. A nil `fileURL` keeps them in memory only (tests and
/// processes that are not the app). Names are unique ignoring case: saving an existing name
/// replaces that template's layout and keeps its id. A file this build cannot read (a newer
/// build's version or tab kind, or a damaged file) is never written over: the first read moves it
/// aside whole (`layout-templates.unreadable-<time>-<id>.json`, beside it), so a downgrade keeps
/// the newer build's templates on disk; if it cannot be moved, every change refuses.
actor LayoutTemplateRepository {
    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.app.next.layout-templates`): its file reads and writes block a thread of
    /// its own, never a cooperative pool thread (the HomeCache pattern).
    // executor: com.cmuxterm.app.next.layout-templates
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.app.next.layout-templates", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated private struct Document: Codable {
        /// The file version this build reads and writes.
        static let currentVersion = 1
        var version = Document.currentVersion
        var templates: [LayoutTemplate]
    }

    /// A rename or delete names no template, or a rename takes another template's name; or the file
    /// could not be read and could not be moved aside, so no change may write over it.
    nonisolated enum Failure: Error, Equatable {
        case notFound
        case nameTaken
        case unreadableFile
    }

    private let fileURL: URL?
    private var templates: [LayoutTemplate]?
    /// The file did not read and could not be moved aside: writes refuse (``Failure/unreadableFile``).
    private var keepsUnreadableFile = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Every template, oldest save first.
    func all() -> [LayoutTemplate] {
        loaded()
    }

    /// Saves `blueprint` as template `name` (replacing a template of that name); returns every template.
    func put(name: String, blueprint: WorkspaceBlueprint, now: Date = Date()) throws -> [LayoutTemplate] {
        var list = loaded()
        if let index = list.firstIndex(where: { Self.same($0.name, name) }) {
            list[index].name = name
            list[index].blueprint = blueprint
            list[index].savedAt = now
        } else {
            list.append(LayoutTemplate(id: UUID().uuidString.lowercased(), name: name, blueprint: blueprint, savedAt: now))
        }
        try write(list)
        return list
    }

    /// Renames template `id` to `name`; returns every template.
    func rename(id: String, to name: String) throws -> [LayoutTemplate] {
        var list = loaded()
        guard let index = list.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        if list.contains(where: { $0.id != id && Self.same($0.name, name) }) { throw Failure.nameTaken }
        list[index].name = name
        try write(list)
        return list
    }

    /// Deletes template `id`; returns every template left.
    func delete(id: String) throws -> [LayoutTemplate] {
        var list = loaded()
        guard list.contains(where: { $0.id == id }) else { throw Failure.notFound }
        list.removeAll { $0.id == id }
        try write(list)
        return list
    }

    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The file's templates, read once; a missing file reads as none, and so does one this build
    /// cannot read, after it is moved aside (``setAside(_:)``).
    private func loaded() -> [LayoutTemplate] {
        if let templates { return templates }
        var read: [LayoutTemplate] = []
        if let fileURL {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let document = try? decoder.blockingDecode(Document.self, from: data),
                   document.version <= Document.currentVersion {
                    read = document.templates
                } else {
                    setAside(fileURL)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // No templates saved yet.
            } catch {
                setAside(fileURL)
            }
        }
        templates = read
        return read
    }

    /// Moves the unreadable file at `fileURL` to a new name beside it (a move never replaces an
    /// existing file), so the next write starts a new file and the old one stays whole.
    private func setAside(_ fileURL: URL) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent(
            "layout-templates.unreadable-\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).json")
        do {
            try FileManager.checked.moveItem(at: fileURL, to: aside)
        } catch {
            keepsUnreadableFile = true
        }
    }

    private func write(_ list: [LayoutTemplate]) throws {
        if keepsUnreadableFile { throw Failure.unreadableFile }
        if let fileURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Document(templates: list))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
        templates = list
    }
}
