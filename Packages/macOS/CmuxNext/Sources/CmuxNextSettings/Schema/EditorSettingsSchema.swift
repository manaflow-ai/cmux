/// The code editor's Settings rows (diff-host S7): `editor.<key>`, the keys the Monaco editor page
/// reads (webviews/src/pages/editor/settings.ts `resolveEditorSettings`), with VS Code's names and
/// the page's defaults. The page toolbar and the Opt-Z word wrap toggle write `editor.wordWrap` and
/// `editor.minimap.enabled` through the one settings write path, which refuses a key the schema
/// does not list, so every key a page control writes is a row here.
///
/// A row with a nil default takes it from the terminal (the font). Every key also takes a default
/// from the person's VS Code, Cursor, Windsurf, VSCodium or Zed settings (`editor.importFrom`,
/// ``EditorSettingsImporter``); a key set in cmux wins.
nonisolated enum EditorSettingsSchema {
    /// `editor.importFrom`: which editor's settings give the defaults.
    static let importFromPath = ["editor", "importFrom"]

    /// Every row's key.
    static var keys: Set<String> { Set(descriptors.map(\.id)) }

    /// The keys an agent may set: every key but `importFrom`, which decides which of the person's
    /// files cmux reads.
    static var agentSettableKeys: Set<String> { keys.subtracting([importFromPath.joined(separator: ".")]) }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                ["editor", "fontFamily"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.terminal.fontFamily", "Font Family"),
                help: SettingsText.keyed("settings.editor.fontFamily.help", "Empty uses the terminal font."),
                kind: .fontFamily,
                default: nil, defaultLabel: SettingsText.keyed("settings.section.terminal", "Terminal"),
                keywords: ["editor", "code", "monaco", "font", "typeface", "monospace", "fontFamily"]
            ),
            SettingDescriptor(
                ["editor", "fontSize"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.terminal.fontSize", "Font Size"),
                help: SettingsText.keyed("settings.editor.fontSize.help", "Empty uses the terminal font size. Cmd-= and Cmd-- change it in one editor."),
                kind: .number(SettingNumber(6...72, step: 1, unit: .points, placeholder: 13)),
                default: nil, defaultLabel: SettingsText.keyed("settings.section.terminal", "Terminal"),
                keywords: ["editor", "code", "monaco", "font", "size", "zoom", "fontSize"]
            ),
            SettingDescriptor(
                ["editor", "fontWeight"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.editor.fontWeight", "Font Weight"),
                kind: .choice([SettingChoice("normal", SettingsText.keyed("settings.choice.normal", "Normal")), SettingChoice("bold", SettingsText.keyed("settings.choice.editor.bold", "Bold")), SettingChoice("300", SettingsText.keyed("settings.choice.editor.light", "Light")), SettingChoice("500", SettingsText.keyed("settings.choice.editor.medium", "Medium")), SettingChoice("600", SettingsText.keyed("settings.choice.editor.semibold", "Semibold"))]),
                default: .string("normal"),
                keywords: ["editor", "code", "monaco", "font", "weight", "bold", "fontWeight"]
            ),
            SettingDescriptor(
                ["editor", "fontLigatures"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.editor.fontLigatures", "Font Ligatures"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "ligatures", "font", "fontLigatures", "calt"]
            ),
            SettingDescriptor(
                ["editor", "lineHeight"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.editor.lineHeight", "Line Height"),
                help: SettingsText.keyed("settings.editor.lineHeight.help", "0 computes it from the font size. A value under 8 multiplies the font size."),
                kind: .number(SettingNumber(0...150, step: 0.1, unit: .points)),
                default: .number(0),
                keywords: ["editor", "code", "monaco", "line", "height", "spacing", "lineHeight"]
            ),
            SettingDescriptor(
                ["editor", "letterSpacing"], section: .editor, group: SettingsText.keyed("settings.group.editorFont", "Font"),
                title: SettingsText.keyed("settings.editor.letterSpacing", "Letter Spacing"),
                kind: .number(SettingNumber(-5...20, step: 0.1, unit: .points)),
                default: .number(0),
                keywords: ["editor", "code", "monaco", "letter", "spacing", "tracking", "letterSpacing"]
            ),
            SettingDescriptor(
                ["editor", "tabSize"], section: .editor, group: SettingsText.keyed("settings.group.editorText", "Indentation and Wrapping"),
                title: SettingsText.keyed("settings.editor.tabSize", "Tab Size"),
                kind: .number(SettingNumber(1...16, step: 1, unit: .count)),
                default: .number(4),
                keywords: ["editor", "code", "monaco", "tab", "indent", "width", "tabSize"]
            ),
            SettingDescriptor(
                ["editor", "insertSpaces"], section: .editor, group: SettingsText.keyed("settings.group.editorText", "Indentation and Wrapping"),
                title: SettingsText.keyed("settings.editor.insertSpaces", "Insert Spaces"),
                help: SettingsText.keyed("settings.editor.insertSpaces.help", "Tab inserts spaces. Off inserts a tab character."),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "spaces", "tabs", "indent", "insertSpaces"]
            ),
            SettingDescriptor(
                ["editor", "detectIndentation"], section: .editor, group: SettingsText.keyed("settings.group.editorText", "Indentation and Wrapping"),
                title: SettingsText.keyed("settings.editor.detectIndentation", "Detect Indentation"),
                help: SettingsText.keyed("settings.editor.detectIndentation.help", "Tab size and spaces follow the file's own indentation."),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "indent", "detect", "detectIndentation"]
            ),
            SettingDescriptor(
                ["editor", "wordWrap"], section: .editor, group: SettingsText.keyed("settings.group.editorText", "Indentation and Wrapping"),
                title: SettingsText.keyed("settings.editor.wordWrap", "Word Wrap"),
                help: SettingsText.keyed("settings.editor.wordWrap.help", "Opt-Z turns it on and off."),
                kind: .choice([SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")), SettingChoice("on", SettingsText.keyed("settings.choice.editor.wrapEdge", "At the Window Edge")), SettingChoice("wordWrapColumn", SettingsText.keyed("settings.choice.editor.wrapColumn", "At the Wrap Column")), SettingChoice("bounded", SettingsText.keyed("settings.choice.editor.wrapBounded", "At the Edge or the Wrap Column"))]),
                default: .string("off"),
                keywords: ["editor", "code", "monaco", "wrap", "word wrap", "soft wrap", "wordWrap"]
            ),
            SettingDescriptor(
                ["editor", "wordWrapColumn"], section: .editor, group: SettingsText.keyed("settings.group.editorText", "Indentation and Wrapping"),
                title: SettingsText.keyed("settings.editor.wordWrapColumn", "Wrap Column"),
                kind: .number(SettingNumber(10...1000, step: 1, unit: .count)),
                default: .number(80),
                keywords: ["editor", "code", "monaco", "wrap", "column", "width", "wordWrapColumn"]
            ),
            SettingDescriptor(
                ["editor", "lineNumbers"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.diff.lineNumbers", "Line Numbers"),
                kind: .choice([SettingChoice("on", SettingsText.keyed("settings.choice.on", "On")), SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")), SettingChoice("relative", SettingsText.keyed("settings.choice.editor.relative", "Relative")), SettingChoice("interval", SettingsText.keyed("settings.choice.editor.interval", "Every 10 Lines"))]),
                default: .string("on"),
                keywords: ["editor", "code", "monaco", "line numbers", "gutter", "relative", "lineNumbers"]
            ),
            SettingDescriptor(
                ["editor", "rulers"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.rulers", "Rulers"),
                help: SettingsText.keyed("settings.editor.rulers.help", "Columns where a vertical line shows."),
                kind: .numberList(SettingNumber(1...1000, step: 1, unit: .count)),
                default: .array([]),
                keywords: ["editor", "code", "monaco", "ruler", "column", "guide", "rulers"]
            ),
            SettingDescriptor(
                ["editor", "minimap", "enabled"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.minimap", "Minimap"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "minimap", "overview"]
            ),
            SettingDescriptor(
                ["editor", "renderWhitespace"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.renderWhitespace", "Show Whitespace"),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.never", "Never")), SettingChoice("boundary", SettingsText.keyed("settings.choice.editor.boundary", "Between Words")), SettingChoice("selection", SettingsText.keyed("settings.choice.editor.selection", "In the Selection")), SettingChoice("trailing", SettingsText.keyed("settings.choice.editor.trailing", "At Line Ends")), SettingChoice("all", SettingsText.keyed("settings.choice.always", "Always"))]),
                default: .string("selection"),
                keywords: ["editor", "code", "monaco", "whitespace", "spaces", "tabs", "invisibles", "renderWhitespace"]
            ),
            SettingDescriptor(
                ["editor", "renderControlCharacters"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.renderControlCharacters", "Show Control Characters"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "control", "characters", "invisible", "renderControlCharacters"]
            ),
            SettingDescriptor(
                ["editor", "renderLineHighlight"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.renderLineHighlight", "Current Line Highlight"),
                kind: .choice([SettingChoice("none", SettingsText.keyed("settings.choice.none", "None")), SettingChoice("gutter", SettingsText.keyed("settings.choice.editor.gutter", "Gutter")), SettingChoice("line", SettingsText.keyed("settings.choice.editor.line", "Line")), SettingChoice("all", SettingsText.keyed("settings.choice.editor.gutterAndLine", "Gutter and Line"))]),
                default: .string("line"),
                keywords: ["editor", "code", "monaco", "highlight", "current line", "renderLineHighlight"]
            ),
            SettingDescriptor(
                ["editor", "bracketPairColorization", "enabled"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.bracketPairColorization", "Color Bracket Pairs"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "bracket", "pairs", "color", "rainbow", "bracketPairColorization"]
            ),
            SettingDescriptor(
                ["editor", "guides", "bracketPairs"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.bracketPairGuides", "Bracket Pair Guides"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "bracket", "guides", "lines"]
            ),
            SettingDescriptor(
                ["editor", "guides", "indentation"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.indentGuides", "Indentation Guides"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "indent", "guides", "lines"]
            ),
            SettingDescriptor(
                ["editor", "matchBrackets"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.matchBrackets", "Highlight Matching Brackets"),
                kind: .choice([SettingChoice("always", SettingsText.keyed("settings.choice.always", "Always")), SettingChoice("near", SettingsText.keyed("settings.choice.editor.near", "Near the Cursor")), SettingChoice("never", SettingsText.keyed("settings.choice.never", "Never"))]),
                default: .string("always"),
                keywords: ["editor", "code", "monaco", "bracket", "match", "matchBrackets"]
            ),
            SettingDescriptor(
                ["editor", "stickyScroll", "enabled"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.stickyScroll", "Sticky Scroll"),
                help: SettingsText.keyed("settings.editor.stickyScroll.help", "The lines that open the scopes around the top line stay at the top while you scroll."),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "sticky", "scroll", "scope", "stickyScroll"]
            ),
            SettingDescriptor(
                ["editor", "folding"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.folding", "Code Folding"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "fold", "folding", "collapse"]
            ),
            SettingDescriptor(
                ["editor", "scrollBeyondLastLine"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.scrollBeyondLastLine", "Scroll Past the Last Line"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "scroll", "last line", "scrollBeyondLastLine"]
            ),
            SettingDescriptor(
                ["editor", "smoothScrolling"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.smoothScrolling", "Smooth Scrolling"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "scroll", "smooth", "smoothScrolling"]
            ),
            SettingDescriptor(
                ["editor", "mouseWheelZoom"], section: .editor, group: SettingsText.keyed("settings.group.editorDisplay", "Display"),
                title: SettingsText.keyed("settings.editor.mouseWheelZoom", "Zoom with Command and the Scroll Wheel"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "zoom", "mouse", "wheel", "mouseWheelZoom"]
            ),
            SettingDescriptor(
                ["editor", "cursorStyle"], section: .editor, group: SettingsText.keyed("settings.group.editorCursor", "Cursor"),
                title: SettingsText.keyed("settings.editor.cursorStyle", "Cursor Style"),
                kind: .choice([SettingChoice("line", SettingsText.keyed("settings.choice.editor.line", "Line")), SettingChoice("block", SettingsText.keyed("settings.choice.editor.block", "Block")), SettingChoice("underline", SettingsText.keyed("settings.choice.editor.underline", "Underline")), SettingChoice("line-thin", SettingsText.keyed("settings.choice.editor.lineThin", "Thin Line")), SettingChoice("block-outline", SettingsText.keyed("settings.choice.editor.blockOutline", "Block Outline")), SettingChoice("underline-thin", SettingsText.keyed("settings.choice.editor.underlineThin", "Thin Underline"))]),
                default: .string("line"),
                keywords: ["editor", "code", "monaco", "cursor", "caret", "block", "cursorStyle"]
            ),
            SettingDescriptor(
                ["editor", "cursorBlinking"], section: .editor, group: SettingsText.keyed("settings.group.editorCursor", "Cursor"),
                title: SettingsText.keyed("settings.editor.cursorBlinking", "Cursor Blinking"),
                kind: .choice([SettingChoice("blink", SettingsText.keyed("settings.choice.blink", "Blink")), SettingChoice("smooth", SettingsText.keyed("settings.choice.editor.smooth", "Smooth")), SettingChoice("phase", SettingsText.keyed("settings.choice.editor.phase", "Phase")), SettingChoice("expand", SettingsText.keyed("settings.choice.editor.expand", "Expand")), SettingChoice("solid", SettingsText.keyed("settings.choice.editor.solid", "Solid"))]),
                default: .string("blink"),
                keywords: ["editor", "code", "monaco", "cursor", "blink", "caret", "cursorBlinking"]
            ),
            SettingDescriptor(
                ["editor", "cursorSmoothCaretAnimation"], section: .editor, group: SettingsText.keyed("settings.group.editorCursor", "Cursor"),
                title: SettingsText.keyed("settings.editor.cursorSmoothCaretAnimation", "Animate Cursor Movement"),
                kind: .choice([SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off")), SettingChoice("explicit", SettingsText.keyed("settings.choice.editor.explicit", "When You Move It")), SettingChoice("on", SettingsText.keyed("settings.choice.always", "Always"))]),
                default: .string("off"),
                keywords: ["editor", "code", "monaco", "cursor", "animation", "smooth", "caret", "cursorSmoothCaretAnimation"]
            ),
            SettingDescriptor(
                ["editor", "cursorSurroundingLines"], section: .editor, group: SettingsText.keyed("settings.group.editorCursor", "Cursor"),
                title: SettingsText.keyed("settings.editor.cursorSurroundingLines", "Lines Kept Around the Cursor"),
                kind: .number(SettingNumber(0...50, step: 1, unit: .count)),
                default: .number(0),
                keywords: ["editor", "code", "monaco", "cursor", "scroll", "margin", "cursorSurroundingLines"]
            ),
            SettingDescriptor(
                ["editor", "multiCursorModifier"], section: .editor, group: SettingsText.keyed("settings.group.editorCursor", "Cursor"),
                title: SettingsText.keyed("settings.editor.multiCursorModifier", "Add a Cursor With"),
                help: SettingsText.keyed("settings.editor.multiCursorModifier.help", "The key you hold while you click to add a cursor."),
                kind: .choice([SettingChoice("alt", SettingsText.keyed("settings.choice.editor.optionClick", "Option-Click")), SettingChoice("ctrlCmd", SettingsText.keyed("settings.choice.editor.commandClick", "Command-Click"))]),
                default: .string("alt"),
                keywords: ["editor", "code", "monaco", "multi cursor", "multiple cursors", "click", "multiCursorModifier"]
            ),
            SettingDescriptor(
                ["editor", "autoClosingBrackets"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.autoClosingBrackets", "Close Brackets"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "bracket", "auto close", "pairs", "autoClosingBrackets"]
            ),
            SettingDescriptor(
                ["editor", "autoClosingQuotes"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.autoClosingQuotes", "Close Quotes"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "quote", "auto close", "autoClosingQuotes"]
            ),
            SettingDescriptor(
                ["editor", "linkedEditing"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.linkedEditing", "Rename Matching Tags Together"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "linked", "tag", "html", "rename", "linkedEditing"]
            ),
            SettingDescriptor(
                ["editor", "quickSuggestions"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.quickSuggestions", "Suggest While Typing"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "suggest", "autocomplete", "completion", "intellisense", "quickSuggestions"]
            ),
            SettingDescriptor(
                ["editor", "wordBasedSuggestions"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.wordBasedSuggestions", "Suggest Words from the File"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "suggest", "words", "completion", "wordBasedSuggestions"]
            ),
            SettingDescriptor(
                ["editor", "acceptSuggestionOnEnter"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.acceptSuggestionOnEnter", "Return Accepts a Suggestion"),
                kind: .choice([SettingChoice("on", SettingsText.keyed("settings.choice.on", "On")), SettingChoice("smart", SettingsText.keyed("settings.choice.editor.smart", "When It Changes the Text")), SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off"))]),
                default: .string("on"),
                keywords: ["editor", "code", "monaco", "suggest", "enter", "return", "acceptSuggestionOnEnter"]
            ),
            SettingDescriptor(
                ["editor", "emptySelectionClipboard"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.emptySelectionClipboard", "Copy the Line When Nothing Is Selected"),
                kind: .toggle,
                default: .bool(true),
                keywords: ["editor", "code", "monaco", "copy", "cut", "line", "clipboard", "emptySelectionClipboard"]
            ),
            SettingDescriptor(
                ["editor", "find", "seedSearchStringFromSelection"], section: .editor, group: SettingsText.keyed("settings.group.editorEditing", "Editing"),
                title: SettingsText.keyed("settings.editor.findSeed", "Find Starts With"),
                kind: .choice([SettingChoice("always", SettingsText.keyed("settings.choice.editor.wordAtCursor", "The Word at the Cursor")), SettingChoice("selection", SettingsText.keyed("settings.choice.editor.selectionOnly", "The Selection Only")), SettingChoice("never", SettingsText.keyed("settings.choice.none", "None"))]),
                default: .string("always"),
                keywords: ["editor", "code", "monaco", "find", "search", "selection", "seedSearchStringFromSelection"]
            ),
            SettingDescriptor(
                ["editor", "autoSave"], section: .editor, group: SettingsText.keyed("settings.group.editorSaving", "Saving"),
                title: SettingsText.keyed("settings.editor.autoSave", "Save Automatically"),
                kind: .choice([SettingChoice("afterDelay", SettingsText.keyed("settings.choice.editor.afterDelay", "After a Pause")), SettingChoice("off", SettingsText.keyed("settings.choice.off", "Off"))]),
                default: .string("afterDelay"),
                keywords: ["editor", "code", "monaco", "save", "auto save", "autoSave"]
            ),
            SettingDescriptor(
                ["editor", "autoSaveDelay"], section: .editor, group: SettingsText.keyed("settings.group.editorSaving", "Saving"),
                title: SettingsText.keyed("settings.editor.autoSaveDelay", "Pause Before Saving"),
                kind: .number(SettingNumber(100...60_000, step: 100, unit: .milliseconds)),
                default: .number(1000),
                keywords: ["editor", "code", "monaco", "save", "delay", "autoSaveDelay"]
            ),
            SettingDescriptor(
                ["editor", "trimTrailingWhitespace"], section: .editor, group: SettingsText.keyed("settings.group.editorSaving", "Saving"),
                title: SettingsText.keyed("settings.editor.trimTrailingWhitespace", "Remove Trailing Spaces on Save"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "trim", "trailing", "whitespace", "save", "trimTrailingWhitespace"]
            ),
            SettingDescriptor(
                ["editor", "insertFinalNewline"], section: .editor, group: SettingsText.keyed("settings.group.editorSaving", "Saving"),
                title: SettingsText.keyed("settings.editor.insertFinalNewline", "End Files with a Newline on Save"),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "final newline", "newline", "save", "insertFinalNewline"]
            ),
            SettingDescriptor(
                ["editor", "formatOnSave"], section: .editor, group: SettingsText.keyed("settings.group.editorSaving", "Saving"),
                title: SettingsText.keyed("settings.editor.formatOnSave", "Format on Save"),
                help: SettingsText.keyed("settings.editor.formatOnSave.help", "Runs the language's formatter when one is installed."),
                kind: .toggle,
                default: .bool(false),
                keywords: ["editor", "code", "monaco", "format", "save", "prettier", "formatOnSave"]
            ),
            SettingDescriptor(
                ["editor", "importFrom"], section: .editor, group: SettingsText.keyed("settings.group.editorDefaults", "Defaults from Other Editors"),
                title: SettingsText.keyed("settings.editor.importFrom", "Take Defaults From"),
                help: SettingsText.keyed("settings.editor.importFrom.help", "cmux reads that editor's settings and keybindings files and never changes them. A setting you make here wins."),
                kind: .choice([SettingChoice("auto", SettingsText.keyed("settings.choice.editor.firstFound", "The First Editor Found")), SettingChoice("vscode", "VS Code"), SettingChoice("cursor", "Cursor"), SettingChoice("windsurf", "Windsurf"), SettingChoice("vscodium", "VSCodium"), SettingChoice("zed", "Zed"), SettingChoice("none", SettingsText.keyed("settings.choice.none", "None"))]),
                default: .string("auto"),
                keywords: ["editor", "code", "monaco", "import", "vscode", "zed", "cursor", "windsurf", "vscodium", "settings", "keybindings"]
            ),
        ]
    }
}
