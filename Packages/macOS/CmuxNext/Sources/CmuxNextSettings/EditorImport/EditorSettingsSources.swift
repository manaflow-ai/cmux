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
        let support = home.appending(path: "Library/Application Support")
        func code(_ folder: String) -> (URL, URL) {
            let user = support.appending(path: folder).appending(path: "User")
            return (user.appending(path: "settings.json"), user.appending(path: "keybindings.json"))
        }
        switch editor {
        case .vscode: return code("Code")
        case .cursor: return code("Cursor")
        case .windsurf: return code("Windsurf")
        case .vscodium: return code("VSCodium")
        case .zed:
            let zed = home.appending(path: ".config/zed")
            return (zed.appending(path: "settings.json"), zed.appending(path: "keymap.json"))
        }
    }

    /// Every file a choice may read (what a watcher watches).
    public func watchedFiles(_ choice: EditorImportChoice) -> [URL] {
        let editors: [ImportableEditor] = switch choice {
        case .none: []
        case .auto: ImportableEditor.allCases
        case .editor(let editor): [editor]
        }
        return editors.flatMap { [files(of: $0).settings, files(of: $0).keys] }
    }

    /// The mapped section of the chosen editor, or of the first editor in ``ImportableEditor/allCases``
    /// order whose settings file parses (`auto`). Nil when there is none.
    public func load(_ choice: EditorImportChoice) -> Found? {
        let editors: [ImportableEditor] = switch choice {
        case .none: []
        case .auto: ImportableEditor.allCases
        case .editor(let editor): [editor]
        }
        for editor in editors {
            let (settingsFile, keysFile) = files(of: editor)
            guard let text = read(settingsFile), let settings = try? JSONC.parse(text), settings.objectValue != nil else { continue }
            let keys = read(keysFile).flatMap { try? JSONC.parse($0) }
            let mapper = EditorSettingsImport()
            let section = editor == .zed ? mapper.zed(settings: settings, keymap: keys)
                : mapper.vscode(settings: settings, keybindings: keys)
            return Found(editor: editor, files: [settingsFile] + (keys == nil ? [] : [keysFile]), section: section)
        }
        return nil
    }
}
