import Testing
@testable import CmuxTerminalCore

@Suite struct GhosttyCopyActionResolverTests {
    private let resolver = GhosttyCopyActionResolver()

    private func binding(
        _ flavor: GhosttyCopyActionResolver.Flavor,
        shortcut: GhosttyTriggerShortcut = GhosttyCopyActionResolver.standardCopyShortcut
    ) -> GhosttyCopyActionResolver.Binding {
        GhosttyCopyActionResolver.Binding(flavor: flavor, shortcut: shortcut)
    }

    @Test func mixedFlavorUsesGhosttyDefaultActionSpelling() {
        #expect(
            GhosttyCopyActionResolver.Flavor.mixed.bindingAction
                == GhosttyCopyActionResolver.defaultAction
        )
    }

    @Test func everyFlavorIsPassedThroughToGhostty() {
        for flavor in GhosttyCopyActionResolver.Flavor.allCases {
            #expect(
                resolver.resolve(bindings: [binding(flavor)])
                    == flavor.bindingAction
            )
        }
    }

    @Test func standardCopyBindingUsesConfiguredPlainFlavor() {
        #expect(
            resolver.resolve(bindings: [binding(.plain)])
                == "copy_to_clipboard:plain"
        )
    }

    @Test func noStandardFlavorOverrideKeepsGhosttyMixedDefault() {
        let nonStandardShortcut = GhosttyTriggerShortcut(
            key: "c",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        #expect(
            resolver.resolve(bindings: [binding(.plain, shortcut: nonStandardShortcut)])
                == GhosttyCopyActionResolver.defaultAction
        )
    }

    @Test func conflictingStandardFlavorBindingsFallBackToMixedDefault() {
        let standard = GhosttyCopyActionResolver.standardCopyShortcut

        #expect(
            resolver.resolve(bindings: [
                binding(.plain, shortcut: standard),
                binding(.html, shortcut: standard),
            ]) == GhosttyCopyActionResolver.defaultAction
        )
    }
}
