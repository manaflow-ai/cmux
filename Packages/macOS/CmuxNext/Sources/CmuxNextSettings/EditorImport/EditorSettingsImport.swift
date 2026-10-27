public import Foundation

/// Maps another editor's settings to the code editor's `editor` section (cmux.json keys, Monaco's
/// and VS Code's names): VS Code and the editors built on it (Cursor, Windsurf, VSCodium) read their
/// `settings.json` and `keybindings.json`; Zed its `settings.json` and `keymap.json`. Pure: it takes
/// parsed JSON and returns the section; ``EditorSettingsSources`` reads the files.
///
/// Only keys the code editor reads come over, in the shape its Settings rows accept, so a value
/// copied into cmux.json loads without a diagnostic. Language blocks (`"[python]"`, Zed's
/// `languages`) become `languages.<id>`; key bindings for editor commands become `keybindings`
/// (VS Code's `{key, command, when}`).
///
/// ```swift
/// let section = EditorSettingsImport().vscode(settings: try JSONC.parse(text), keybindings: nil)
/// section["tabSize"] // .number(2)
/// ```
public nonisolated struct EditorSettingsImport: Sendable {
    public init() {}

    // MARK: VS Code

    /// The `editor` keys VS Code names `editor.<key>` with the same values.
    static let vscodeSameKeys: [String] = [
        "fontFamily", "fontSize", "lineHeight", "letterSpacing", "tabSize", "insertSpaces", "detectIndentation", "wordWrap",
        "wordWrapColumn", "minimap.enabled", "lineNumbers", "renderWhitespace", "renderControlCharacters", "renderLineHighlight",
        "bracketPairColorization.enabled", "guides.indentation", "matchBrackets", "stickyScroll.enabled", "folding",
        "scrollBeyondLastLine", "smoothScrolling", "mouseWheelZoom", "cursorStyle", "cursorBlinking", "cursorSurroundingLines",
        "multiCursorModifier", "linkedEditing", "acceptSuggestionOnEnter", "emptySelectionClipboard",
        "find.seedSearchStringFromSelection", "formatOnSave",
    ]

    /// The keys a language block may set (`editor.languages.<id>`), as the page reads them.
    static let languageKeys: [String] = ["tabSize", "insertSpaces", "detectIndentation", "wordWrap", "rulers", "formatOnSave"]

    /// The `editor` section for a VS Code `settings.json` (parsed, comments stripped) and its
    /// `keybindings.json` (nil when the file is absent).
    public func vscode(settings: JSONValue, keybindings: JSONValue?) -> JSONValue {
        var out: [String: JSONValue] = [:]
        let root = settings.objectValue ?? [:]
        func flat(_ key: String) -> JSONValue? { root[key] ?? settings.value(at: key.split(separator: ".").map(String.init)) }
        for key in Self.vscodeSameKeys {
            if let value = flat("editor." + key).flatMap({ Self.vscodeValue(key, $0) }) { Self.set(&out, key, value) }
        }
        if let weight = flat("editor.fontWeight").flatMap(Self.fontWeight) { out["fontWeight"] = weight }
        if let ligatures = flat("editor.fontLigatures") {
            // VS Code also takes a feature string ("'ss01', 'calt'"): ligatures on.
            out["fontLigatures"] = .bool(ligatures.boolValue ?? !(ligatures.stringValue ?? "").isEmpty)
        }
        if let rulers = flat("editor.rulers").flatMap(Self.rulers) { out["rulers"] = rulers }
        for key in ["autoClosingBrackets", "autoClosingQuotes"] {
            if let value = flat("editor." + key) { out[key] = .bool(value.boolValue ?? (value.stringValue != "never")) }
        }
        // VS Code's `true`, `"active"` or `false`.
        if let value = flat("editor.guides.bracketPairs") { Self.set(&out, "guides.bracketPairs", .bool(value.boolValue ?? (value.stringValue != nil))) }
        if let value = flat("editor.quickSuggestions") {
            out["quickSuggestions"] = .bool(value.boolValue ?? (value.objectValue?.values.contains { $0 == .bool(true) || $0 == .string("on") } ?? false))
        }
        if let value = flat("editor.wordBasedSuggestions") { out["wordBasedSuggestions"] = .bool(value.boolValue ?? (value.stringValue != "off")) }
        if let value = flat("editor.cursorSmoothCaretAnimation") {
            if let flag = value.boolValue { out["cursorSmoothCaretAnimation"] = .string(flag ? "on" : "off") }
            else if let text = value.stringValue, ["off", "explicit", "on"].contains(text) { out["cursorSmoothCaretAnimation"] = .string(text) }
        }
        switch flat("files.autoSave")?.stringValue {
        case "off"?: out["autoSave"] = "off"
        // cmux saves after a pause or when the page hides; VS Code's focus and window modes are closest to that.
        case "afterDelay"?, "onFocusChange"?, "onWindowChange"?: out["autoSave"] = "afterDelay"
        default: break
        }
        if let delay = flat("files.autoSaveDelay")?.doubleValue, (100...60_000).contains(delay) { out["autoSaveDelay"] = .number(delay.rounded()) }
        for key in ["trimTrailingWhitespace", "insertFinalNewline"] {
            if let flag = flat("files." + key)?.boolValue { out[key] = .bool(flag) }
        }
        var languages: [String: JSONValue] = [:]
        for (key, block) in root where key.hasPrefix("[") {
            guard let members = block.objectValue else { continue }
            var language: [String: JSONValue] = [:]
            for name in Self.languageKeys {
                guard let value = members["editor." + name] else { continue }
                if name == "rulers" { if let rulers = Self.rulers(value) { language[name] = rulers } }
                else if let value = Self.vscodeValue(name, value) { language[name] = value }
            }
            guard !language.isEmpty else { continue }
            // "[typescript][javascript]" names more than one language.
            for id in key.split(whereSeparator: { $0 == "[" || $0 == "]" }).map(String.init) where Self.isLanguageID(id) {
                languages[id.lowercased()] = Self.merged(languages[id.lowercased()], language)
            }
        }
        if !languages.isEmpty { out["languages"] = .object(languages) }
        if let bindings = keybindings.map(Self.vscodeKeybindings), !bindings.isEmpty { out["keybindings"] = .array(bindings) }
        return .object(out)
    }

    /// A VS Code value in the shape the row for `key` accepts, or nil.
    static func vscodeValue(_ key: String, _ value: JSONValue) -> JSONValue? {
        guard let descriptor = SettingsSchema.descriptor(for: ["editor"] + key.split(separator: ".").map(String.init)) else {
            return value
        }
        if descriptor.accepts(value) { return value }
        // Numbers out of a row's range keep the default rather than load with a warning.
        if case .number = descriptor.kind, let number = value.doubleValue, value.stringValue == nil {
            return descriptor.accepts(.number(number.rounded())) ? .number(number.rounded()) : nil
        }
        return nil
    }

    static func fontWeight(_ value: JSONValue) -> JSONValue? {
        if let text = value.stringValue, text == "normal" || text == "bold" { return .string(text) }
        guard let number = value.doubleValue ?? value.stringValue.flatMap(Double.init) else { return nil }
        // The weights the row offers: the nearest one.
        let choices: [(Double, String)] = [(300, "300"), (400, "normal"), (500, "500"), (600, "600"), (700, "bold")]
        return .string(choices.min { abs($0.0 - number) < abs($1.0 - number) }!.1)
    }

    static func rulers(_ value: JSONValue) -> JSONValue? {
        guard let items = value.arrayValue else { return nil }
        // VS Code also takes `{column, color}`.
        let columns = items.compactMap { $0.doubleValue ?? $0["column"]?.doubleValue }.filter { (1...1000).contains($0) }
        return .array(columns.prefix(8).map { .number($0.rounded()) })
    }

    /// Editor command bindings from `keybindings.json`: Monaco's command ids and their removals
    /// (`-editor.action.x`); workbench commands (files, panels, terminals) are not the editor's.
    static func vscodeKeybindings(_ value: JSONValue) -> [JSONValue] {
        (value.arrayValue ?? []).prefix(500).compactMap { item in
            guard let key = item["key"]?.stringValue, let command = item["command"]?.stringValue, isEditorCommand(command) else { return nil }
            var entry: [String: JSONValue] = ["key": .string(key), "command": .string(command)]
            if let when = item["when"]?.stringValue, !when.isEmpty, when.count <= 300 { entry["when"] = .string(when) }
            return .object(entry)
        }
    }

    /// Monaco's commands besides `editor.*`: cursor undo and find.
    static let monacoCommands: Set<String> = ["cursorUndo", "cursorRedo", "actions.find", "actions.findWithSelection", "undo", "redo"]

    static func isEditorCommand(_ command: String) -> Bool {
        let id = command.hasPrefix("-") ? String(command.dropFirst()) : command
        guard id.count <= 128, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else { return false }
        return id.hasPrefix("editor.") || monacoCommands.contains(id)
    }

    // MARK: Zed

    /// Zed actions with a Monaco command of the same meaning.
    static let zedActions: [String: String] = [
        "editor::SelectAllMatches": "editor.action.selectHighlights",
        "editor::SelectNext": "editor.action.addSelectionToNextFindMatch",
        "editor::SelectPrevious": "editor.action.addSelectionToPreviousFindMatch",
        "editor::ToggleComments": "editor.action.commentLine",
        "editor::MoveLineUp": "editor.action.moveLinesUpAction",
        "editor::MoveLineDown": "editor.action.moveLinesDownAction",
        "editor::DuplicateLineDown": "editor.action.copyLinesDownAction",
        "editor::DuplicateLineUp": "editor.action.copyLinesUpAction",
        "editor::DeleteLine": "editor.action.deleteLines",
        "editor::AddSelectionAbove": "editor.action.insertCursorAbove",
        "editor::AddSelectionBelow": "editor.action.insertCursorBelow",
        "editor::Fold": "editor.fold",
        "editor::UnfoldLines": "editor.unfold",
        "editor::FoldAll": "editor.foldAll",
        "editor::UnfoldAll": "editor.unfoldAll",
        "editor::ToggleSoftWrap": "editor.action.toggleWordWrap",
        "editor::Indent": "editor.action.indentLines",
        "editor::Outdent": "editor.action.outdentLines",
        "editor::NewlineBelow": "editor.action.insertLineAfter",
        "editor::NewlineAbove": "editor.action.insertLineBefore",
        "editor::SelectLargerSyntaxNode": "editor.action.smartSelect.expand",
        "editor::SelectSmallerSyntaxNode": "editor.action.smartSelect.shrink",
        "editor::MoveToEnclosingBracket": "editor.action.jumpToBracket",
        "editor::ConvertToUpperCase": "editor.action.transformToUppercase",
        "editor::ConvertToLowerCase": "editor.action.transformToLowercase",
        "editor::SortLinesCaseSensitive": "editor.action.sortLinesAscending",
        "editor::JoinLines": "editor.action.joinLines",
        "editor::Format": "editor.action.formatDocument",
        "editor::SelectLine": "editor.action.expandLineSelection",
        "editor::ShowCompletions": "editor.action.triggerSuggest",
        "buffer_search::Deploy": "actions.find",
        "go_to_line::Toggle": "editor.action.gotoLine",
    ]

    /// The `editor` section for a Zed `settings.json` and its `keymap.json` (nil when absent).
    public func zed(settings: JSONValue, keymap: JSONValue?) -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let family = settings["buffer_font_family"]?.stringValue, !family.isEmpty { out["fontFamily"] = .string(family) }
        if let size = settings["buffer_font_size"]?.doubleValue, (6...72).contains(size) { out["fontSize"] = .number(size) }
        if let weight = settings["buffer_font_weight"].flatMap(Self.fontWeight) { out["fontWeight"] = weight }
        switch settings["buffer_line_height"] {
        case .string("comfortable")?: out["lineHeight"] = .number(1.618)
        case .string("standard")?: out["lineHeight"] = .number(1.3)
        case let value?: if let custom = value["custom"]?.doubleValue, custom > 0, custom < 8 { out["lineHeight"] = .number(custom) }
        case nil: break
        }
        // Zed's font features `{"calt": false}` turn ligatures off.
        if let calt = settings["buffer_font_features"]?["calt"]?.boolValue { out["fontLigatures"] = .bool(calt) }
        Self.zedLanguage(settings, into: &out)
        if let relative = settings["relative_line_numbers"]?.boolValue, relative { out["lineNumbers"] = "relative" }
        if settings["gutter"]?["line_numbers"]?.boolValue == false { out["lineNumbers"] = "off" }
        if let whitespace = settings["show_whitespaces"]?.stringValue,
           ["none", "boundary", "selection", "trailing", "all"].contains(whitespace) { out["renderWhitespace"] = .string(whitespace) }
        if let blink = settings["cursor_blink"]?.boolValue { out["cursorBlinking"] = .string(blink ? "blink" : "solid") }
        if let shape = settings["cursor_shape"]?.stringValue {
            let map = ["bar": "line", "block": "block", "underline": "underline", "hollow": "block-outline"]
            if let style = map[shape] { out["cursorStyle"] = .string(style) }
        }
        switch settings["minimap"]?["show"]?.stringValue {
        case "always"?, "auto"?: Self.set(&out, "minimap.enabled", .bool(true))
        case "never"?: Self.set(&out, "minimap.enabled", .bool(false))
        default: break
        }
        if let beyond = settings["scroll_beyond_last_line"]?.stringValue { out["scrollBeyondLastLine"] = .bool(beyond != "off") }
        if let flag = settings["remove_trailing_whitespace_on_save"]?.boolValue { out["trimTrailingWhitespace"] = .bool(flag) }
        if let flag = settings["ensure_final_newline_on_save"]?.boolValue { out["insertFinalNewline"] = .bool(flag) }
        switch settings["autosave"] {
        case .string("off")?: out["autoSave"] = "off"
        case .string(_)?: out["autoSave"] = "afterDelay"
        case let value?:
            if let delay = value["after_delay"]?["milliseconds"]?.doubleValue {
                out["autoSave"] = "afterDelay"
                if (100...60_000).contains(delay) { out["autoSaveDelay"] = .number(delay.rounded()) }
            }
        case nil: break
        }
        if let languages = settings["languages"]?.objectValue {
            var mapped: [String: JSONValue] = [:]
            for (name, block) in languages {
                var language: [String: JSONValue] = [:]
                Self.zedLanguage(block, into: &language)
                let picked = language.filter { Self.languageKeys.contains($0.key) }
                let id = name.lowercased().replacingOccurrences(of: " ", with: "")
                if !picked.isEmpty, Self.isLanguageID(id) { mapped[id] = .object(picked) }
            }
            if !mapped.isEmpty { out["languages"] = .object(mapped) }
        }
        if let bindings = keymap.map(Self.zedKeybindings), !bindings.isEmpty { out["keybindings"] = .array(bindings) }
        return .object(out)
    }

    /// The keys a Zed settings object and a Zed language block share.
    static func zedLanguage(_ settings: JSONValue, into out: inout [String: JSONValue]) {
        if let size = settings["tab_size"]?.doubleValue, (1...16).contains(size) { out["tabSize"] = .number(size.rounded()) }
        if let hard = settings["hard_tabs"]?.boolValue { out["insertSpaces"] = .bool(!hard) }
        let length = settings["preferred_line_length"]?.doubleValue
        if let length, (10...1000).contains(length) { out["wordWrapColumn"] = .number(length.rounded()) }
        switch settings["soft_wrap"]?.stringValue {
        case "none"?: out["wordWrap"] = "off"
        case "editor_width"?, "prefer_line"?: out["wordWrap"] = "on"
        case "preferred_line_length"?: out["wordWrap"] = "wordWrapColumn"
        case "bounded"?: out["wordWrap"] = "bounded"
        default: break
        }
        if let guides = settings["wrap_guides"].flatMap(Self.rulers) { out["rulers"] = guides }
        if let format = settings["format_on_save"] {
            out["formatOnSave"] = .bool(format.boolValue ?? (format.stringValue.map { $0 != "off" } ?? false))
        }
    }

    /// Bindings of the editor's contexts (`Editor`) whose actions have a Monaco command.
    static func zedKeybindings(_ value: JSONValue) -> [JSONValue] {
        var out: [JSONValue] = []
        for block in value.arrayValue ?? [] {
            if let context = block["context"]?.stringValue, !context.contains("Editor") { continue }
            for (key, action) in (block["bindings"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                let name = action.stringValue ?? action.arrayValue?.first?.stringValue
                guard let name, let command = zedActions[name] else { continue }
                out.append(["key": .string(key), "command": .string(command)])
                if out.count >= 500 { return out }
            }
        }
        return out
    }

    // MARK: Helpers

    static func isLanguageID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+#._-".contains($0)) }
    }

    /// Sets a dotted key (`minimap.enabled`) in `section`, keeping the object's other members.
    static func set(_ section: inout [String: JSONValue], _ key: String, _ value: JSONValue) {
        let parts = key.split(separator: ".")
        guard let name = parts.first.map(String.init) else { return }  // `""` or `"."`: no member to set
        guard parts.count > 1 else { section[name] = value; return }
        var child = section[name]?.objectValue ?? [:]
        set(&child, parts.dropFirst().joined(separator: "."), value)
        section[name] = .object(child)
    }

    /// `base` with `overlay`'s members on top, objects merged member by member.
    static func merged(_ base: JSONValue?, _ overlay: [String: JSONValue]) -> JSONValue {
        var members = base?.objectValue ?? [:]
        for (key, value) in overlay {
            if let object = value.objectValue, members[key]?.objectValue != nil {
                members[key] = merged(members[key], object)
            } else {
                members[key] = value
            }
        }
        return .object(members)
    }

    /// The code editor's section: `imported` under `own` (a key set in cmux.json wins, objects
    /// merged member by member).
    public static func section(imported: JSONValue, own: JSONValue) -> JSONValue {
        merged(imported.objectValue == nil ? .object([:]) : imported, own.objectValue ?? [:])
    }
}
