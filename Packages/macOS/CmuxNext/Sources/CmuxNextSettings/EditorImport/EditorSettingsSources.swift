public import Foundation

/// Where the code editor takes its defaults from (`editor.importFrom`): another editor's settings
/// files, read and never written. Rust (cmux-config `editor_import`, the `import.editor_*` ops)
/// owns the rules: which editors a choice reads, where their files are, and how VS Code's and Zed's
/// settings map to the `editor` section. This reads the files.
///
/// ```swift
/// let sources = EditorSettingsSources(home: FileManager.default.homeDirectoryForCurrentUser)
/// let found = sources.load(EditorSettingsSources.choice(setting: nil)) // the first editor with a settings file
/// ```
public nonisolated struct EditorSettingsSources: Sendable {
    /// What ``load(_:)`` found: the editor's name, the files it read, and the mapped `editor` section.
    public struct Found: Sendable, Equatable {
        /// The name a person knows the editor by (a product name: not translated).
        public let name: String
        /// The files read: its settings file, then its key bindings file when there is one.
        public let files: [URL]
        /// The mapped `editor` section.
        public let section: JSONValue
    }

    /// The person's home folder; tests pass a temporary folder.
    public let home: URL
    /// Reads one file; nil when it is absent or unreadable. Tests replace it.
    let read: @Sendable (URL) -> String?

    /// - Parameters:
    ///   - home: The folder the editors' files are found under (the person's home folder).
    ///   - read: Reads one file; the default reads it as UTF-8 from disk.
    public init(home: URL, read: @escaping @Sendable (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) {
        self.home = home
        self.read = read
    }

    /// The choice `editor.importFrom` holds: `auto`, `none` or an editor id (unknown is `auto`).
    public static func choice(setting: String?) -> String {
        let request: JSONValue = setting.map { .object(["setting": .string($0)]) } ?? .object([:])
        return SettingsRust.answer("import.editor_choice", request)["choice"]?.stringValue ?? "auto"
    }

    /// Every file a choice may read (what a watcher watches).
    public func watchedFiles(_ choice: String) -> [URL] {
        let reply = SettingsRust.answer("import.editor_files", .object(["home": .string(home.path), "choice": .string(choice)]))
        return (reply["files"]?.arrayValue ?? []).compactMap { $0.stringValue.map { URL(fileURLWithPath: $0) } }
    }

    /// The mapped section of the chosen editor, or of the first editor whose settings file parses
    /// (`auto`). Nil when there is none.
    public func load(_ choice: String) -> Found? {
        var texts: [String: JSONValue] = [:]
        for file in watchedFiles(choice) { texts[file.path] = read(file).map(JSONValue.string) }
        let reply = SettingsRust.answer("import.editor_load", .object([
            "home": .string(home.path), "choice": .string(choice), "texts": .object(texts)]))
        guard let name = reply["name"]?.stringValue, let section = reply["section"] else { return nil }
        let files = (reply["files"]?.arrayValue ?? []).compactMap { $0.stringValue.map { URL(fileURLWithPath: $0) } }
        return Found(name: name, files: files, section: section)
    }

    /// The code editor's section: `imported` under `own` (a key set in cmux.json wins).
    public static func section(imported: JSONValue, own: JSONValue) -> JSONValue {
        SettingsRust.answer("import.editor_section", .object(["imported": imported, "own": own]))["section"] ?? own
    }
}
