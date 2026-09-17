import AppKit
import CmuxCommandPalette

extension ContentView {
    static let commandPaletteComputerUseOpenSetupCommandId = "palette.computerUse.openSetup"
    static let commandPaletteComputerUseAccessibilityCommandId = "palette.computerUse.accessibility"
    static let commandPaletteComputerUseScreenRecordingCommandId = "palette.computerUse.screenRecording"

    /// Command-palette entry points for the one Computer Use onboarding flow.
    /// The context gate mirrors the feature flag used by the menu-bar UX, so a
    /// disabled rollout cannot leave stale onboarding commands visible.
    static func commandPaletteComputerUseContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let subtitle = constant(
            String(localized: "computerUse.onboarding.media.title", defaultValue: "Computer use")
        )
        let whenEnabled: (CommandPaletteContextSnapshot) -> Bool = {
            $0.bool(CommandPaletteContextKeys.computerUseUXEnabled)
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteComputerUseOpenSetupCommandId,
                title: constant(
                    String(localized: "computerUse.onboarding.windowTitle", defaultValue: "Computer Use Setup")
                ),
                subtitle: subtitle,
                keywords: [
                    "computer", "use", "cua", "mcp", "setup", "onboarding", "permissions",
                ],
                when: whenEnabled
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteComputerUseAccessibilityCommandId,
                title: constant(
                    String(localized: "computerUse.onboarding.accessibility.title", defaultValue: "Grant Accessibility")
                ),
                subtitle: subtitle,
                keywords: [
                    "computer", "use", "cua", "accessibility", "permission", "privacy", "setup",
                ],
                when: whenEnabled
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteComputerUseScreenRecordingCommandId,
                title: constant(
                    String(localized: "computerUse.onboarding.screenRecording.title", defaultValue: "Grant Screen Recording")
                ),
                subtitle: subtitle,
                keywords: [
                    "computer", "use", "cua", "screen", "recording", "capture", "permission", "setup",
                ],
                when: whenEnabled
            ),
        ]
    }

    /// Registers handlers against the same coordinator used by Settings and
    /// automatic onboarding. This keeps the palette from creating a second
    /// onboarding window controller or a separate permission flow.
    func registerComputerUseCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteComputerUseOpenSetupCommandId) {
            guard AppDelegate.shared?.presentComputerUseOnboarding() == true else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: Self.commandPaletteComputerUseAccessibilityCommandId) {
            guard AppDelegate.shared?.presentComputerUseOnboarding(startingAt: .accessibility) == true else {
                NSSound.beep()
                return
            }
        }
        registry.register(commandId: Self.commandPaletteComputerUseScreenRecordingCommandId) {
            guard AppDelegate.shared?.presentComputerUseOnboarding(startingAt: .screenRecording) == true else {
                NSSound.beep()
                return
            }
        }
    }
}
