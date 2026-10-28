import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

@MainActor
@Suite("Ghostty security defaults", .serialized)
struct GhosttySecurityDefaultsTests {
    /// `clipboard-write` stays Ghostty's `allow` by default; cmux then asks
    /// for a program write only when the person is not using the terminal
    /// (``TerminalClipboardRequests/writeDecision(userInitiated:requiresConfirmation:focused:sinceInput:)``).
    @Test(arguments: ["", "clipboard-write = allow\n"])
    func programClipboardWritesAreAllowedByDefault(_ text: String) throws {
        #expect(try resolvedString("clipboard-write", configText: text) == "allow")
    }

    @Test func explicitClipboardWriteAskStillAsks() throws {
        #expect(try resolvedString("clipboard-write", configText: "clipboard-write = ask\n") == "ask")
    }

    /// A program write the person can see coming (the terminal has focus and they typed or clicked in it a
    /// moment ago, e.g. Claude Code's copy) is committed silently, as Ghostty does.
    @Test func programWriteRightAfterInputInTheFocusedTerminalIsCommittedSilently() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: true, sinceInput: .seconds(1)) == .write)
    }

    /// Output of a terminal the person is not using (a background tab, or long after their last input) could
    /// put a command on the clipboard for a later paste: it asks first.
    @Test func programWriteFromATerminalWithoutFocusAsks() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: false, sinceInput: .seconds(1)) == .confirm)
    }

    @Test func programWriteLongAfterTheLastInputAsks() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: true, sinceInput: .seconds(60)) == .confirm)
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: true, sinceInput: nil) == .confirm)
    }

    @Test func programWriteGhosttyAsksAboutShowsTheDialog() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: true,
                                                        focused: true, sinceInput: .zero) == .confirm)
    }

    @Test func userCopyNeverShowsTheDialog() {
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: true, requiresConfirmation: true,
                                                        focused: false, sinceInput: nil) == .write)
    }

    /// The input window: input within it lets a focused terminal's program write; older input does not.
    @Test func theRecentInputWindowIsShort() {
        let window = TerminalClipboardRequests.programWriteInputWindow
        #expect(window <= .seconds(10))
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: true, sinceInput: window) == .write)
        #expect(TerminalClipboardRequests.writeDecision(userInitiated: false, requiresConfirmation: false,
                                                        focused: true, sinceInput: window + .milliseconds(1)) == .confirm)
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

        let built = try #require(GhosttyConfigInputs.testing(configFile: file.path).buildConfig())
        defer { built.free() }
        let config = try #require(built.config)
        return try read(config)
    }
}
