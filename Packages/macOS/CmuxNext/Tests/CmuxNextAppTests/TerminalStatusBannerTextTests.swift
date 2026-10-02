import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// The terminal's link banner must not crash when its string table is gone:
/// a DEV app whose folder was deleted trapped in `Bundle.module` here when
/// cmux-tui disconnected.
@MainActor struct TerminalStatusBannerTextTests {
    private let missing = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: [])

    @Test func missingStringTableFallsBackToEnglish() {
        #expect(TerminalStatusBanner.text(for: .exited, strings: missing) == "Process exited")
        #expect(
            TerminalStatusBanner.text(for: .disconnected(.connectionLost, reconnecting: true), strings: missing)
                == "Reconnecting…"
        )
        #expect(
            TerminalStatusBanner.text(for: .disconnected(.connectionLost, reconnecting: false), strings: missing)
                == "Disconnected: connection lost · Click or type to reconnect"
        )
        #expect(TerminalStatusBanner.text(for: .connected, strings: missing) == nil)
    }

    /// The safe lookup searches where SwiftPM puts the bundle, so the real
    /// table still loads (in the app and under `swift test`).
    @Test func terminalStringTableIsFound() {
        #expect(ModuleResourceBundle.terminal.bundle != nil)
    }
}

/// The lookup reads the real table: German comes back, not the English default.
@MainActor struct TerminalStatusBannerTranslationTests {
    @Test func germanTableIsRead() {
        let german = ModuleResourceBundle.terminal.localization("de")
        #expect(german.bundle != nil)
        #expect(TerminalStatusBanner.text(for: .exited, strings: german) == "Prozess beendet")
    }
}
