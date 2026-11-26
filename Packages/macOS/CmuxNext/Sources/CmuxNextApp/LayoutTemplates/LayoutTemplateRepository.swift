import CmuxNextDevices
import Foundation

/// The layout templates of this Mac, in one JSON file of this build's support folder
/// (`layout-templates.json` beside the sidebar snapshot); the file is the source of truth and
/// every change rewrites it atomically. A nil `fileURL` keeps them in memory only (tests and
/// processes that are not the app). Names are unique ignoring case: saving an existing name
/// replaces that template's layout and keeps its id.
actor LayoutTemplateRepository {
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
        struct Request: Encodable { var templates: [LayoutTemplate]; var name: String; var blueprint: WorkspaceBlueprint
                                    var savedAt: Date; var newId: String }
        let list = try Self.ask("app_themes_templates_put", Request(templates: loaded(), name: name, blueprint: blueprint,
                                                                   savedAt: now, newId: UUID().uuidString.lowercased()))
        try write(list)
        return list
    }

    /// Renames template `id` to `name`; returns every template.
    func rename(id: String, to name: String) throws -> [LayoutTemplate] {
        struct Request: Encodable { var templates: [LayoutTemplate]; var id: String; var name: String }
        let list = try Self.ask("app_themes_templates_rename", Request(templates: loaded(), id: id, name: name))
        try write(list)
        return list
    }

    /// Deletes template `id`; returns every template left.
    func delete(id: String) throws -> [LayoutTemplate] {
        struct Request: Encodable { var templates: [LayoutTemplate]; var id: String }
        let list = try Self.ask("app_themes_templates_delete", Request(templates: loaded(), id: id))
        try write(list)
        return list
    }

    /// The index of the template named `name` in `names`, ignoring case and surrounding whitespace.
    nonisolated static func index(named name: String, in names: [String]) -> Int? {
        struct Request: Encodable { var templates: [[String: String]]; var name: String }
        struct Answer: Decodable { var index: Int? }
        return AppRules.ask("app_themes_templates_find", Request(templates: names.map { ["name": $0] }, name: name),
                                 as: Answer.self)?.index
    }

    /// Rust's list after a change (dates as reference-date seconds, so none is rounded), or its refusal.
    private static func ask(_ operation: String, _ request: some Encodable) throws -> [LayoutTemplate] {
        struct Answer: Decodable { var templates: [LayoutTemplate]?; var failure: String? }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        guard let body = try? encoder.encode(request), let data = AppRules.call(operation, body),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw Failure.notFound }
        if let templates = answer.templates { return templates }
        throw answer.failure == "nameTaken" ? Failure.nameTaken : Failure.notFound
    }

    /// The file's templates, read once; an unreadable or missing file reads as none.
    private func loaded() -> [LayoutTemplate] {
        if let templates { return templates }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode(Document.self, from: $0) }?.templates ?? []
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
