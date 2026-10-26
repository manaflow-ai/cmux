public import Foundation

/// The "Import Memories" texts (Resources/Localizable.xcstrings). Product names are brand names and stay as
/// they are in every language.
public nonisolated enum ChiefMemoryImportStrings {
    public static var productClaudeCode: String { "Claude Code" }
    public static var productCodex: String { "Codex" }
    public static var productChatGPT: String { "ChatGPT" }
    public static var productClaudeAI: String { "claude.ai" }
    public static var productExport: String { text("import.product.export", "a chat export") }

    public static var title: String { text("import.title", "Import Memories") }
    public static var lead: String {
        text("import.lead", "Bring what Claude Code, Codex, ChatGPT or claude.ai already know about you into your Chief. It runs in the background and your Chief keeps answering.")
    }
    public static var safety: String {
        text("import.safety", "Passwords and API keys are never copied. A backup is made first, and you can undo the import.")
    }
    public static var restartNote: String {
        text("import.restartNote", "Your Chief restarts for a moment while the memory is written.")
    }
    public static var nothingFound: String {
        text("import.nothingFound", "Nothing found on this Mac. Export your data from ChatGPT or claude.ai, save the zip in Downloads, or choose the file.")
    }
    public static var importButton: String { text("import.button", "Import") }
    public static var chooseFile: String { text("import.chooseFile", "Choose File…") }
    public static var choosePrompt: String { text("import.choosePrompt", "Choose a ChatGPT or claude.ai export (zip)") }
    public static var working: String { text("import.working", "Importing memories…") }
    public static var undo: String { text("import.undo", "Undo") }
    public static var undone: String { text("import.undone", "Memory import undone.") }
    public static var nothingToUndo: String { text("import.nothingToUndo", "There is no memory import to undo.") }
    public static var nothingNew: String { text("import.nothingNew", "Nothing new to import: your Chief already has all of it.") }
    public static var failed: String { text("import.failed", "Memory import failed") }
    public static var noTool: String { text("import.noTool", "The Chief tool is missing from this build, so memories cannot be imported.") }
    public static var signInFirst: String { text("import.signInFirst", "Sign in to cmux Cloud to import into a Cloud Chief.") }

    public static var offerMany: String { text("import.offerMany", "Bring your memory from other AI tools") }
    public static func offer(_ products: String) -> String { String(format: text("import.offer", "Bring your memory from %@"), products) }
    public static func claudeCode(_ count: Int) -> String { String(format: text("import.source.claudeCode", "Claude Code conversations (%lld)"), count) }
    public static func claudeMemory(_ count: Int) -> String { String(format: text("import.source.claudeMemory", "Claude Code memory notes (%lld)"), count) }
    public static func codex(_ count: Int) -> String { String(format: text("import.source.codex", "Codex memory notes (%lld)"), count) }
    public static func chatgptExport(_ file: String) -> String { String(format: text("import.source.chatgpt", "ChatGPT export: %@"), file) }
    public static func claudeAIExport(_ file: String) -> String { String(format: text("import.source.claudeAI", "claude.ai export: %@"), file) }
    public static func exportZip(_ file: String) -> String { String(format: text("import.source.export", "Chat export: %@"), file) }
    public static func done(_ count: Int) -> String { String(format: text("import.done", "Brought %lld memories into your Chief."), count) }
    public static func tooCostly(_ dollars: String) -> String {
        String(format: text("import.tooCostly", "Summarizing this would cost about $%@, so it was not started. Pick fewer sources."), dollars)
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
