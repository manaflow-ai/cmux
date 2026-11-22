import Foundation
import CmuxNextDaemon
import CmuxNextTerminal
import Testing
@testable import CmuxNextApp

/// The config's `shell-integration`, `shell-integration-features` and
/// `cursor-style-blink` reach the terminal env as Ghostty would set them.
struct ShellIntegrationSettingsTests {
    @Test func mapsTheConfigOntoTheIntegration() {
        let settings = GhosttyShellIntegrationSettings(mode: "zsh", features: 0b011001, cursorBlink: false)
        let integration = AppEnvironment.shellIntegration(settings, resources: "/R/ghostty", binary: "/R/bin/ghostty")
        #expect(integration.mode == .zsh)
        #expect(integration.features == [.cursor, .sshEnv, .sshTerminfo])
        #expect(integration.featuresValue == "cursor:steady,ssh-env,ssh-terminfo")
        #expect(integration.ghosttyBinary == "/R/bin/ghostty")

        let off = AppEnvironment.shellIntegration(GhosttyShellIntegrationSettings(mode: "none", features: 0, cursorBlink: nil),
                                                  resources: "/R/ghostty", binary: nil)
        #expect(off.shell(for: "/bin/zsh") == nil)
        #expect(off.featuresValue == nil)

        // No config loaded: Ghostty's defaults.
        let defaults = AppEnvironment.shellIntegration(nil, resources: "/R/ghostty", binary: nil)
        #expect(defaults.mode == .detect && defaults.features == .ghosttyDefault)
    }

    /// The app tells the daemon it resolved the integration only when the
    /// resources really hold the scripts; otherwise the daemon integrates.
    @Test func resolvesOnlyWithTheIntegrationScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-si-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(!AppEnvironment.resolvesShellIntegration(resources: root.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell-integration"),
                                                withIntermediateDirectories: true)
        #expect(AppEnvironment.resolvesShellIntegration(resources: root.path))
        #expect(!AppEnvironment.resolvesShellIntegration(resources: nil))
    }

    /// The loaded default config (`GhosttyRuntime.shared`) reports Ghostty's
    /// defaults unless the user's config changes them; the bits must decode.
    @MainActor @Test func runtimeSettingsDecode() {
        guard let settings = GhosttyRuntime.shared.shellIntegrationSettings else { return }
        #expect(GhosttyShellIntegration.Mode(rawValue: settings.mode) != nil)
        #expect(settings.features < 1 << 6)
    }
}
