import AppKit
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Ghostty's app-level `CONFIG_CHANGE` hands the host a clone (`GhosttyActionDecoder`), and the
/// host owns it from then on. The runtime cloned it again and kept the second copy, so the first
/// leaked: a whole parsed config (arena, keybinds, theme) for every reload and every light/dark flip.
@MainActor @Suite(.serialized) struct GhosttyConfigAdoptionTests {
    @Test func adoptingAnAppliedConfigKeepsThatConfigInsteadOfCloningIt() throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let current = try #require(runtime.config)
        let restore = try #require(ghostty_config_clone(current))
        defer { runtime.adoptAppliedConfig(restore) }

        let text = """
        background = #282a36
        foreground = #f8f8f2

        """
        let applied = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(applied, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(applied)

        runtime.adoptAppliedConfig(applied)

        #expect(runtime.config == applied, "the runtime kept a clone; the config it was handed leaked")
    }
}
