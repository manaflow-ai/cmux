import CmuxNextVSCodeServer
import Foundation

/// User-facing text of VS Code (Inline). Keys live in Resources/VSCodeInline.xcstrings.
enum VSCodeInlineStrings {
    static var notInstalled: String { String(localized: "vscodeInline.notInstalled", defaultValue: "Visual Studio Code is not installed on this Mac.", table: "VSCodeInline", bundle: .module) }
    static var serverMissing: String { String(localized: "vscodeInline.serverMissing", defaultValue: "This VS Code install cannot serve in the browser: its code-tunnel CLI is missing.", table: "VSCodeInline", bundle: .module) }
    static var thisMacOnly: String { String(localized: "vscodeInline.thisMacOnly", defaultValue: "VS Code (Inline) opens folders on this Mac only.", table: "VSCodeInline", bundle: .module) }
    static var noFolder: String { String(localized: "vscodeInline.noFolder", defaultValue: "No folder to open: focus a terminal, or run this from the palette to pick one.", table: "VSCodeInline", bundle: .module) }
    static var panelTitle: String { String(localized: "vscodeInline.panel.title", defaultValue: "Open Folder in VS Code (Inline)", table: "VSCodeInline", bundle: .module) }
    static var panelPrompt: String { String(localized: "vscodeInline.panel.prompt", defaultValue: "Open in VS Code", table: "VSCodeInline", bundle: .module) }

    /// What to tell the person when the server failed, or nil when it was stopped on purpose.
    static func failure(_ error: any Error) -> String? {
        guard let error = error as? VSCodeServeWebError else { return startFailed(error.localizedDescription) }
        switch error {
        case .stopped: return nil
        case .serverMissing: return serverMissing
        case .launchFailed(let reason): return startFailed(reason)
        case .exitedBeforeReady:
            return startFailed(String(localized: "vscodeInline.reason.exited", defaultValue: "it exited before it was ready", table: "VSCodeInline", bundle: .module))
        case .startupTimedOut:
            return startFailed(String(localized: "vscodeInline.reason.timedOut", defaultValue: "it did not answer within a minute", table: "VSCodeInline", bundle: .module))
        case .tokenFileFailed:
            return startFailed(String(localized: "vscodeInline.reason.token", defaultValue: "its connection token could not be written", table: "VSCodeInline", bundle: .module))
        }
    }

    private static func startFailed(_ reason: String) -> String {
        String(format: String(localized: "vscodeInline.startFailed", defaultValue: "The VS Code inline server did not start: %@", table: "VSCodeInline", bundle: .module), reason)
    }
}
