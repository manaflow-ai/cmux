import Testing
import UniformTypeIdentifiers
@testable import CmuxWindowing

@Suite("DefaultTerminalRegistrar")
@MainActor
struct DefaultTerminalRegistrarTests {
    @Test("registers the ssh scheme and two content-type targets")
    func targetInventory() {
        #expect(DefaultTerminalRegistrar.urlSchemes == ["ssh"])
        #expect(DefaultTerminalRegistrar.contentTypeIdentifiers == [
            "com.apple.terminal.shell-script",
            "public.unix-executable"
        ])
        #expect(DefaultTerminalRegistrar.targetCount == 3)
    }

    @Test("resolves a known content-type identifier")
    func resolvesKnownContentType() {
        let resolved = DefaultTerminalRegistrar.contentType(forIdentifier: "public.unix-executable")
        #expect(resolved == .unixExecutable)
    }

    @Test("imports an unknown content-type identifier instead of returning nil")
    func importsUnknownContentType() {
        let resolved = DefaultTerminalRegistrar.contentType(forIdentifier: "com.apple.terminal.shell-script")
        #expect(resolved.identifier == "com.apple.terminal.shell-script")
    }
}
