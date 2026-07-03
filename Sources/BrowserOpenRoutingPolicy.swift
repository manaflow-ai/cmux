import AppKit

struct BrowserOpenRoutingPolicy {
    private let modifierPolicy: OpenRoutingModifierPolicy

    nonisolated init(modifierPolicy: OpenRoutingModifierPolicy = OpenRoutingModifierPolicy()) {
        self.modifierPolicy = modifierPolicy
    }

    nonisolated func shouldOpenInCmuxBrowser(
        settingEnabled: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        settingEnabled && !modifierPolicy.shouldBypassCmuxOpenRouting(modifierFlags: modifierFlags)
    }
}
