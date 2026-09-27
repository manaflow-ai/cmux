import Foundation
import Testing
@testable import CmuxFoundation

/// The managed `# cmux themes` block that `cmux themes` and the Settings
/// theme gallery both write into cmux's Ghostty config.
@Suite("Managed cmux themes block")
struct CmuxManagedThemeBlockTests {
    @Test("Applying to an empty file writes only the block")
    func appliesToEmptyContents() {
        #expect(CmuxManagedThemeBlock.applying(rawThemeValue: "light:A,dark:B", to: "") == """
        # cmux themes start
        theme = light:A,dark:B
        # cmux themes end

        """)
    }

    @Test("Applying replaces the old block and keeps the user's lines above it")
    func replacesExistingBlock() {
        let existing = """
        font-size = 13
        # cmux themes start
        theme = Old
        # cmux themes end
        cursor-style = bar

        """
        #expect(CmuxManagedThemeBlock.applying(rawThemeValue: "light:New,dark:New", to: existing) == """
        font-size = 13
        cursor-style = bar

        # cmux themes start
        theme = light:New,dark:New
        # cmux themes end

        """)
    }

    @Test("Clearing keeps other lines, or returns nil when only the block was there")
    func clearsBlock() {
        let blockOnly = CmuxManagedThemeBlock.applying(rawThemeValue: "Nord", to: "")
        #expect(CmuxManagedThemeBlock.clearing(blockOnly) == nil)

        let withUserLine = CmuxManagedThemeBlock.applying(rawThemeValue: "Nord", to: "font-size = 13\n")
        #expect(CmuxManagedThemeBlock.clearing(withUserLine) == "font-size = 13\n")
    }

    @Test("Encoding always names both sides, mirroring a missing one")
    func encodesBothSides() {
        #expect(CmuxManagedThemeBlock.encodedThemeValue(light: "A", dark: "B") == "light:A,dark:B")
        #expect(CmuxManagedThemeBlock.encodedThemeValue(light: "A", dark: nil) == "light:A,dark:A")
        #expect(CmuxManagedThemeBlock.encodedThemeValue(light: " ", dark: "B") == "light:B,dark:B")
        #expect(CmuxManagedThemeBlock.encodedThemeValue(light: nil, dark: nil) == nil)
    }

    @Test("Theme pairs read conditional, plain, and one-sided values")
    func parsesThemePairs() {
        #expect(CmuxManagedThemeBlock.themePair(fromRawValue: "light:A, dark:B")
            == CmuxTerminalThemePair(light: "A", dark: "B"))
        #expect(CmuxManagedThemeBlock.themePair(fromRawValue: "Nord")
            == CmuxTerminalThemePair(light: "Nord", dark: "Nord"))
        #expect(CmuxManagedThemeBlock.themePair(fromRawValue: "dark:B")
            == CmuxTerminalThemePair(light: nil, dark: "B"))
        #expect(CmuxManagedThemeBlock.themePair(fromRawValue: "light:A,Fallback")
            == CmuxTerminalThemePair(light: "A", dark: "Fallback"))
        #expect(CmuxManagedThemeBlock.themePair(fromRawValue: nil)
            == CmuxTerminalThemePair(light: nil, dark: nil))
    }
}

@Suite("Managed cmux themes config file")
struct CmuxManagedThemeConfigFileTests {
    private func makeFile() -> CmuxManagedThemeConfigFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-block-\(UUID().uuidString)", isDirectory: true)
        return CmuxManagedThemeConfigFile(url: directory.appendingPathComponent("config.ghostty"))
    }

    @Test("Write creates the directory and file, and clear removes a block-only file")
    func writeThenClear() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }

        #expect(try file.readContents() == nil)
        try file.write(rawThemeValue: "light:A,dark:B")
        #expect(try file.readContents()?.contains("theme = light:A,dark:B") == true)

        try file.clear()
        #expect(try file.readContents() == nil)
        try file.clear()
    }

    @Test("Restore puts back the exact captured contents")
    func restoresSnapshot() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }

        try file.restore("font-size = 13\n# a comment\n")
        let snapshot = try file.readContents()
        try file.write(rawThemeValue: "Nord")
        try file.restore(snapshot)
        #expect(try file.readContents() == "font-size = 13\n# a comment\n")
    }

    @Test("A theme value with a newline is refused without writing")
    func refusesMultilineValue() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }

        #expect(throws: CmuxManagedThemeConfigFile.WriteError.multilineThemeValue) {
            try file.write(rawThemeValue: "Nord\nfont-size = 99")
        }
        #expect(try file.readContents() == nil)
    }
}
