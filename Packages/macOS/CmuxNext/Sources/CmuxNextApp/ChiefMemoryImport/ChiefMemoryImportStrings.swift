import Foundation

/// The "Import Memories" texts (Resources/ChiefMemoryImport.xcstrings). Product names are brand names and stay as
/// they are in every language.
nonisolated enum ChiefMemoryImportStrings {
    static var productClaudeCode: String { "Claude Code" }
    static var productCodex: String { "Codex" }
    static var productChatGPT: String { "ChatGPT" }
    static var productClaudeAI: String { "claude.ai" }
    static var productExport: String { text("import.product.export", "a chat export") }

    static var title: String { text("import.title", "Import Memories") }
    static var lead: String {
        text("import.lead", "Bring what Claude Code, Codex, ChatGPT or claude.ai already know about you into your Chief. It runs in the background and your Chief keeps answering.")
    }
    static var safety: String {
        text("import.safety", "Passwords and API keys are never copied. A backup is made first, and you can undo the import.")
    }
    static var restartNote: String {
        text("import.restartNote", "Your Chief restarts for a moment while the memory is written.")
    }
    static var nothingFound: String {
        text("import.nothingFound", "Nothing found on this Mac. Export your data from ChatGPT or claude.ai, save the zip in Downloads, or choose the file.")
    }
    static var importButton: String { text("import.button", "Import") }
    static var chooseFile: String { text("import.chooseFile", "Choose File…") }
    static var choosePrompt: String { text("import.choosePrompt", "Choose a ChatGPT or claude.ai export (zip)") }
    static var working: String { text("import.working", "Importing memories…") }
    static var undo: String { text("import.undo", "Undo") }
    static var undone: String { text("import.undone", "Memory import undone.") }
    static var nothingToUndo: String { text("import.nothingToUndo", "There is no memory import to undo.") }
    static var nothingNew: String { text("import.nothingNew", "Nothing new to import: your Chief already has all of it.") }
    static var failed: String { text("import.failed", "Memory import failed") }
    static var noTool: String { text("import.noTool", "The Chief tool is missing from this build, so memories cannot be imported.") }
    static var signInFirst: String { text("import.signInFirst", "Sign in to cmux Cloud to import into a Cloud Chief.") }

    static func offer(_ products: String) -> String { String(format: text("import.offer", "Bring your memory from %@"), products) }
    static func claudeCode(_ count: Int) -> String { String(format: text("import.source.claudeCode", "Claude Code conversations (%lld)"), count) }
    static func claudeMemory(_ count: Int) -> String { String(format: text("import.source.claudeMemory", "Claude Code memory notes (%lld)"), count) }
    static func codex(_ count: Int) -> String { String(format: text("import.source.codex", "Codex memory notes (%lld)"), count) }
    static func chatgptExport(_ file: String) -> String { String(format: text("import.source.chatgpt", "ChatGPT export: %@"), file) }
    static func claudeAIExport(_ file: String) -> String { String(format: text("import.source.claudeAI", "claude.ai export: %@"), file) }
    static func exportZip(_ file: String) -> String { String(format: text("import.source.export", "Chat export: %@"), file) }
    static func done(_ count: Int) -> String { String(format: text("import.done", "Brought %lld memories into your Chief."), count) }
    static func tooCostly(_ dollars: String) -> String {
        String(format: text("import.tooCostly", "Summarizing this would cost about $%@, so it was not started. Pick fewer sources."), dollars)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ChiefMemoryImport", bundle: .module)
    }
}
