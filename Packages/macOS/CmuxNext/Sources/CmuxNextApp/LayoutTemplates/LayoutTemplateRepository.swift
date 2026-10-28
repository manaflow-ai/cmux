import CmuxNextCompat
import Foundation

/// The layout templates of this Mac, in one JSON file of this build's support folder
/// (`layout-templates.json` beside the sidebar snapshot); the file is the source of truth and
/// every change rewrites it atomically. A nil `fileURL` keeps them in memory only (tests and
/// processes that are not the app). Names are unique ignoring case: saving an existing name
/// replaces that template's layout and keeps its id.
actor LayoutTemplateRepository {
    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.app.next.layout-templates`): its file reads and writes block a thread of
    /// its own, never a cooperative pool thread (the HomeCache pattern).
    // executor: com.cmuxterm.app.next.layout-templates
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.app.next.layout-templates", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated private struct Document: Codable {
        var version = 1
        var templates: [LayoutTemplate]
    }

    /// A rename or delete names no template, or a rename takes another template's name.
    nonisolated enum Failure: Error, Equatable {
        case notFound
        case nameTaken
    }

    private let fileURL: URL?
    private var templates: [LayoutTemplate]?

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

    /// The file's templates, read once; an unreadable or missing file reads as none.
    private func loaded() -> [LayoutTemplate] {
        if let templates { return templates }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.blockingDecode(Document.self, from: $0) }?.templates ?? []
        templates = read
        return read
    }

    private func write(_ list: [LayoutTemplate]) throws {
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
