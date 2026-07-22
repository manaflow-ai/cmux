import CmuxCommandPalette

/// A closure-free snapshot of one live command-palette action.
struct CommandPaletteControlRequestItem {
    let id: String
    let title: String
    let subtitle: String
    let shortcutHint: String?
    let keywords: [String]
    let dismissOnRun: Bool
    let arguments: [CmuxActionArgumentDefinition]
}
