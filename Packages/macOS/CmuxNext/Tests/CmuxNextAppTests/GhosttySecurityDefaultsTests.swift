import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

@MainActor
@Suite("Ghostty security defaults", .serialized)
struct GhosttySecurityDefaultsTests {
    /// Program clipboard writes (OSC 52, e.g. Claude Code copying text) are
    /// silent by default, as in Ghostty and classic cmux: no consent dialog.
    @Test(arguments: ["", "clipboard-write = allow\n"])
    func programClipboardWritesAreAllowedByDefault(_ text: String) throws {
        #expect(try resolvedString("clipboard-write", configText: text) == "allow")
    }

    @Test func explicitClipboardWriteAskStillAsks() throws {
        #expect(try resolvedString("clipboard-write", configText: "clipboard-write = ask\n") == "ask")
    }

    @Test func programWriteWithoutConfirmationIsCommittedSilently() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false) == .write)
    }

    @Test func programWriteGhosttyAsksAboutShowsTheDialog() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: true) == .confirm)
    }

    @Test func userCopyNeverShowsTheDialog() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: true, requiresConfirmation: true) == .write)
    }

    @Test func explicitClipboardWriteDenyStaysDenied() throws {
        #expect(try resolvedString("clipboard-write", configText: "clipboard-write = deny\n") == "deny")
    }

    @Test func themeClipboardWriteDenyStaysDenied() throws {
        #expect(try resolvedString("clipboard-write", configText: "", themeText: "clipboard-write = deny\n") == "deny")
    }

    @Test func cmuxUsesABoundedViewerImageDefault() throws {
        #expect(try resolvedUInt32("image-storage-limit", configText: "") == 5_000_000)
    }

    @Test func userConfigOverridesTheViewerImageDefault() throws {
        #expect(try resolvedUInt32("image-storage-limit", configText: "image-storage-limit = 1234567\n") == 1_234_567)
    }

    @Test func userThemeOverridesTheViewerImageDefault() throws {
        #expect(try resolvedUInt32("image-storage-limit", configText: "", themeText: "image-storage-limit = 1234567\n") == 1_234_567)
    }

    private func resolvedString(_ key: String, configText: String, themeText: String? = nil) throws -> String? {
        try withConfig(configText, themeText: themeText) { config in
            var value: UnsafePointer<CChar>?
            let found = GhosttyRuntime.configGet(config, &value, key: key)
            #expect(found)
            return value.map { String(cString: $0) }
        }
    }

    private func resolvedUInt32(_ key: String, configText: String, themeText: String? = nil) throws -> UInt32 {
        try withConfig(configText, themeText: themeText) { config in
            var value: UInt32 = 0
            #expect(GhosttyRuntime.configGet(config, &value, key: key))
            return value
        }
    }

    private func withConfig<T>(_ text: String, themeText: String? = nil,
                               read: (ghostty_config_t) throws -> T) throws -> T {
        _ = GhosttyRuntime.shared // ghostty_config_new requires ghostty_init
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        var configText = text
        if let themeText {
            let theme = directory.appendingPathComponent("theme")
            try Data(themeText.utf8).write(to: theme)
            configText += "theme = \(theme.path)\n"
        }
        try Data(configText.utf8).write(to: file)

        // The file goes in as an argument, never through setenv: a write after
        // ghostty_init frees the environ copy libghostty reads, and
        // ghostty_config_finalize then crashed this suite (signal 11).
        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity,
                                                            configFile: file.path))
        defer { ghostty_config_free(config) }
        return try read(config)
    }
}
