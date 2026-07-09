import Testing

@testable import CmuxFoundation

@Suite
struct AuxiliaryWindowRegistryTests {
    @Test
    func defaultRegistryClaimsRegisteredAuxiliaryWindow() {
        #expect(AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut("cmux.settings"))
        #expect(AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut("cmux.about"))
        // The pairing window must stay registered: the Cmd+W regression is that
        // closing "Pair iPhone" otherwise closes a terminal tab behind it.
        #expect(AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut("cmux.mobilePairingWindow"))
        #expect(AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut("cmux.spinnerGallery"))
    }

    @Test
    func defaultRegistryRejectsUnregisteredAndNilIdentifiers() {
        #expect(!AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut("cmux.mainTerminal"))
        #expect(!AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut(""))
        #expect(!AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut(nil))
    }

    @Test
    func customRegistryUsesItsOwnIdentifierSet() {
        let registry = AuxiliaryWindowRegistry(identifiers: ["only.this"])
        #expect(registry.shouldOwnCloseShortcut("only.this"))
        #expect(!registry.shouldOwnCloseShortcut("cmux.settings"))
    }
}
