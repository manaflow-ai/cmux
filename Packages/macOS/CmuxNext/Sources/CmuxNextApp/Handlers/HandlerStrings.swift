import Foundation

/// Localized strings for the action handlers. Keys live in
/// Resources/Handlers.xcstrings (en, ja). Refusal reasons are diagnostics
/// for logs and the CLI and stay English, like other control-socket errors.
enum HandlerStrings {
    static var renamePaneTitle: String {
        String(localized: "handlers.rename.pane.title", defaultValue: "Rename Pane", table: "Handlers", bundle: .module)
    }

    static var renameScreenTitle: String {
        String(localized: "handlers.rename.screen.title", defaultValue: "Rename Screen", table: "Handlers", bundle: .module)
    }

    static var findTitle: String {
        String(localized: "handlers.find.title", defaultValue: "Find in Terminal", table: "Handlers", bundle: .module)
    }

    static var findConfirm: String {
        String(localized: "handlers.find.confirm", defaultValue: "Find", table: "Handlers", bundle: .module)
    }
}
