import Foundation
import Testing
@testable import CmuxNextTerminal

/// The user's Ghostty `clipboard-read` key reaches the clipboard-read broker
/// as Ghostty resolves it (plans/cmux-next/ghostty-config.md, broker layer 4).
@MainActor @Suite(.serialized) struct GhosttyClipboardReadTests {
    /// libghostty needs `ghostty_init` (the shared runtime) before configs.
    init() { _ = GhosttyRuntime.shared }

    @Test func clipboardReadFollowsTheConfigAndDefaultsToAsk() {
        #expect(GhosttyRuntime.clipboardReadValue(configText: "") == "ask")
        #expect(GhosttyRuntime.clipboardReadValue(configText: "clipboard-read = allow\n") == "allow")
        #expect(GhosttyRuntime.clipboardReadValue(configText: "clipboard-read = deny\n") == "deny")
    }
}
