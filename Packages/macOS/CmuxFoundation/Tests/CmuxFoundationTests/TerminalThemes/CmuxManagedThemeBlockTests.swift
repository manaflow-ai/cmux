import Foundation
import Testing
@testable import CmuxFoundation

/// The managed `# cmux themes` block that `cmux themes` and the Settings
/// theme gallery both write into cmux's Ghostty config.
@Suite("Managed cmux themes block")
struct CmuxManagedThemeBlockTests {
    private let block = CmuxManagedThemeBlock()

    @Test("Applying to an empty file writes only the block")
    func appliesToEmptyContents() {
        #expect(block.applying(rawThemeValue: "light:A,dark:B", to: "") == """
        # cmux themes start
        theme = light:A,dark:B
        # cmux themes end

        """)
    }

    @Test("Applying replaces the old block and keeps the user's lines apart")
    func replacesExistingBlock() {
        let existing = """
        font-size = 13
        # cmux themes start
        theme = Old
        # cmux themes end
        cursor-style = bar

        """
        #expect(block.applying(rawThemeValue: "light:New,dark:New", to: existing) == """
        font-size = 13
        cursor-style = bar

        # cmux themes start
        theme = light:New,dark:New
        # cmux themes end

        """)
    }

    @Test("A CRLF file keeps one block and CRLF endings across repeated writes")
    func crlfFileDoesNotGrow() {
        var contents = "font-size = 13\r\n"
        for theme in ["A", "B", "C"] {
            contents = block.applying(rawThemeValue: theme, to: contents)
        }
        #expect(contents == "font-size = 13\r\n\r\n# cmux themes start\r\ntheme = C\r\n# cmux themes end\r\n")
        #expect(block.themeValue(in: contents) == "C")
        #expect(block.clearing(contents) == "font-size = 13\r\n")
    }

    @Test("A file without a trailing newline gets the block on its own lines")
    func noTrailingNewline() {
        let once = block.applying(rawThemeValue: "A", to: "font-size = 13")
        #expect(once == "font-size = 13\n\n# cmux themes start\ntheme = A\n# cmux themes end\n")

        let blockAtEnd = "font-size = 13\n# cmux themes start\ntheme = A\n# cmux themes end"
        #expect(block.applying(rawThemeValue: "B", to: blockAtEnd) == "font-size = 13\n\n# cmux themes start\ntheme = B\n# cmux themes end\n")
        #expect(block.clearing(blockAtEnd) == "font-size = 13\n")
    }

    @Test("Clearing keeps other lines, or returns nil when only the block was there")
    func clearsBlock() {
        #expect(block.clearing(block.applying(rawThemeValue: "Nord", to: "")) == nil)
        #expect(block.clearing(block.applying(rawThemeValue: "Nord", to: "font-size = 13\n")) == "font-size = 13\n")
    }

    @Test("Reads the theme value only from inside the managed block")
    func readsManagedThemeValue() {
        #expect(block.themeValue(in: "theme = Outside\n") == nil)
        #expect(block.themeValue(in: "theme = Outside\n" + block.applying(rawThemeValue: "light:A,dark:B", to: "")) == "light:A,dark:B")
    }

    @Test("Encoding always names both sides, mirroring a missing one")
    func encodesBothSides() {
        #expect(block.encodedThemeValue(light: "A", dark: "B") == "light:A,dark:B")
        #expect(block.encodedThemeValue(light: "A", dark: nil) == "light:A,dark:A")
        #expect(block.encodedThemeValue(light: " ", dark: "B") == "light:B,dark:B")
        #expect(block.encodedThemeValue(light: nil, dark: nil) == nil)
    }

    @Test("Theme pairs read conditional, plain, and one-sided values")
    func parsesThemePairs() {
        #expect(block.themePair(fromRawValue: "light:A, dark:B") == CmuxTerminalThemePair(light: "A", dark: "B"))
        #expect(block.themePair(fromRawValue: "Nord") == CmuxTerminalThemePair(light: "Nord", dark: "Nord"))
        #expect(block.themePair(fromRawValue: "dark:B") == CmuxTerminalThemePair(light: nil, dark: "B"))
        #expect(block.themePair(fromRawValue: "light:A,Fallback") == CmuxTerminalThemePair(light: "A", dark: "Fallback"))
        #expect(block.themePair(fromRawValue: nil) == CmuxTerminalThemePair(light: nil, dark: nil))
    }
}

@Suite("Managed cmux themes config file")
struct CmuxManagedThemeConfigFileTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-theme-block-\(UUID().uuidString)", isDirectory: true)

    private var file: CmuxManagedThemeConfigFile {
        CmuxManagedThemeConfigFile(url: root.appendingPathComponent("config.ghostty"))
    }

    @Test("Write creates the directory and file, and clear removes a block-only file")
    func writeThenClear() throws {
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try file.readContents() == nil)
        try file.write(rawThemeValue: "light:A,dark:B")
        #expect(try file.managedThemeValue() == "light:A,dark:B")

        try file.clear()
        #expect(try file.readContents() == nil)
        try file.clear()
    }

    @Test("Setting a managed value back keeps edits made outside the block")
    func setManagedValueKeepsOtherEdits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "font-size = 13\n".write(to: file.url, atomically: true, encoding: .utf8)

        let before = try file.managedThemeValue()
        try file.write(rawThemeValue: "Nord")
        try (try file.readContents()! + "cursor-style = bar\n").write(to: file.url, atomically: true, encoding: .utf8)
        try file.setManagedThemeValue(before)

        #expect(try file.readContents() == "font-size = 13\n\ncursor-style = bar\n")
    }

    @Test("A theme value with a newline is refused without writing")
    func refusesMultilineValue() throws {
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: CmuxManagedThemeConfigFile.WriteError.multilineThemeValue) {
            try file.write(rawThemeValue: "Nord\nfont-size = 99")
        }
        #expect(try file.readContents() == nil)
    }
}
