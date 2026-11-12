internal import AppKit
import Testing
@testable import CmuxTerminalCore

@Suite("Terminal chrome configuration identity")
struct TerminalChromeConfigurationIdentityTests {
    @Test
    func tracksEveryPersistentChromeInput() {
        let baselineConfiguration = GhosttyConfig()
        let baseline = identity(for: baselineConfiguration)
        #expect(identity(for: baselineConfiguration) == baseline)

        var tabBarFont = baselineConfiguration
        tabBarFont.surfaceTabBarFontSize += 1
        #expect(identity(for: tabBarFont) != baseline)

        var unfocusedOpacity = baselineConfiguration
        unfocusedOpacity.unfocusedSplitOpacity = 0.42
        #expect(identity(for: unfocusedOpacity) != baseline)

        var unfocusedFill = baselineConfiguration
        unfocusedFill.unfocusedSplitFill = .systemPink
        #expect(identity(for: unfocusedFill) != baseline)

        var divider = baselineConfiguration
        divider.splitDividerColor = .systemOrange
        #expect(identity(for: divider) != baseline)

        #expect(
            identity(
                for: baselineConfiguration,
                usesHostLayerBackground: true
            ) != baseline
        )
    }

    private func identity(
        for configuration: GhosttyConfig,
        usesHostLayerBackground: Bool = false
    ) -> TerminalChromeConfigurationIdentity {
        TerminalChromeConfigurationIdentity(
            configuration: configuration,
            usesHostLayerBackground: usesHostLayerBackground
        )
    }
}
