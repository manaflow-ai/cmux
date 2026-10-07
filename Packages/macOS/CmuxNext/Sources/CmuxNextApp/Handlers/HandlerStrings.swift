import Foundation

/// Localized strings for the action handlers. Keys live in
/// Resources/Handlers.xcstrings (en, ja). Refusal reasons are user-visible
/// too (CLI, logs) and live in `RefusalStrings` (Resources/Refusals.xcstrings).
enum HandlerStrings {
    static var renamePaneTitle: String {
        String(localized: "handlers.rename.pane.title", defaultValue: "Rename Pane", table: "Handlers", bundle: .module)
    }

    static var renameScreenTitle: String {
        String(localized: "handlers.rename.screen.title", defaultValue: "Rename Screen", table: "Handlers", bundle: .module)
    }
}
