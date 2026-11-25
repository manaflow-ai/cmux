public import Foundation

/// Where the code editor takes its defaults from (`editor.importFrom`): another editor's settings
/// files, read and never written. ``EditorSettingsSources/load(_:)`` reads them;
/// ``EditorSettingsImport`` maps them.
///
/// ```swift
/// let sources = EditorSettingsSources(home: FileManager.default.homeDirectoryForCurrentUser)
/// let found = sources.load(.auto) // the first editor with a settings file, mapped
/// ```
public nonisolated struct EditorSettingsSources: Sendable {
    /// What ``load(_:)`` found: the editor, the files it read, and the mapped `editor` section.
    public struct Found: Sendable, Equatable {
        /// The editor whose settings were read.
        public let editor: ImportableEditor
        /// The files read: its settings file, then its key bindings file when there is one.
        public let files: [URL]
        /// The mapped `editor` section (``EditorSettingsImport``).
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

    /// The settings file and the key bindings file of `editor`.
    public func files(of editor: ImportableEditor) -> (settings: URL, keys: URL) {
        let files = watchedFiles(.editor(editor))
        return (files.first ?? home, files.dropFirst().first ?? home)
    }

    /// Every file a choice may read (what a watcher watches), in the order ``load(_:)`` tries them.
    public func watchedFiles(_ choice: EditorImportChoice) -> [URL] {
        let reply = SettingsRust.answer("import.editor_files", ["home": .string(home.path), "choice": .string(choice.id)])
        return (reply["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(filePath: $0) }
    }

    /// The mapped section of the chosen editor, or of the first editor in ``ImportableEditor/allCases``
    /// order whose settings file parses (`auto`). Nil when there is none. This reads the files;
    /// `import.editor_load` picks the editor and maps them.
    public func load(_ choice: EditorImportChoice) -> Found? {
        var texts: [String: JSONValue] = [:]
        for file in watchedFiles(choice) {
            if let text = read(file) { texts[file.path] = .string(text) }
        }
        guard !texts.isEmpty else { return nil }
        let request: JSONValue = ["home": .string(home.path), "choice": .string(choice.id), "texts": .object(texts)]
        let reply = SettingsRust.answer("import.editor_load", request)
        guard let editor = reply["editor"]?.stringValue.flatMap(ImportableEditor.init(rawValue:)),
              let section = reply["section"] else { return nil }
        let files = (reply["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { URL(filePath: $0) }
        return Found(editor: editor, files: files, section: section)
    }
}
