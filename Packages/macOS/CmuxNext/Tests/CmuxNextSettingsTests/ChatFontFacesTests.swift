@testable import CmuxNextSettings
import Foundation
import Testing

/// The agent chat's font files (`agentPane.display.font.faces`, a community typography theme's font
/// pack), through the loader Rust answers: the reader's own cases (bytes, keys) are its Rust tests
/// (cmux-tui/crates/cmux-config/src/font_faces/tests.rs, app_ops/effective.rs), and the theme file's
/// path to the chat page.
@Suite(.serialized) struct ChatFontFacesTests {
    static let woff2 = Data("wOF2".utf8) + Data([0, 1, 0, 0]) + Data("rest of the font".utf8)

    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "cn-font-faces-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        @discardableResult func write(_ data: Data, _ name: String) throws -> String {
            let file = url.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            return file.path
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    static func file(_ path: String) -> JSONValue { .string("file:" + path) }

    @Test func aGoodFaceBecomesADataURL() throws {
        let folder = try Folder()
        let path = try folder.write(Self.woff2, "Lora-Italic.woff2")
        let faces = ChatFontFaces.Loader().dataURLs(["Lora:italic": Self.file(path)])
        let url = try #require(faces["Lora:italic"])
        #expect(url.hasPrefix("data:font/woff2;base64,d09GMg"), "\(url)")
        #expect(url == "data:font/woff2;base64," + Self.woff2.base64EncodedString())
    }

    @Test func badFilesAreSkipped() throws {
        let folder = try Folder()
        let png = try folder.write(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), "x.woff2")
        let mismatched = try folder.write(Self.woff2, "x.ttf")
        let svg = try folder.write(Self.woff2, "x.svg")
        let big = try folder.write(Self.woff2 + Data(count: 2 << 20), "big.woff2")
        let values: [JSONValue] = [
            Self.file(png), Self.file(mismatched), Self.file(svg), Self.file(big),
            Self.file(folder.url.appending(path: "missing.woff2").path), Self.file(folder.url.path),
            .string("x.woff2"), .string("file:fonts/x.woff2"), .number(3),
        ]
        for value in values {
            #expect(ChatFontFaces.Loader().dataURLs(["A": value]).isEmpty, "\(value)")
        }
    }

    @Test func aSymlinkIsSkipped() throws {
        let folder = try Folder()
        let real = try folder.write(Self.woff2, "real.woff2")
        let link = folder.url.appending(path: "link.woff2").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(ChatFontFaces.Loader().dataURLs(["A": Self.file(link)]).isEmpty)
        #expect(ChatFontFaces.Loader().dataURLs(["A": Self.file(real)]).count == 1)
    }

    @Test func atMostEightFacesLoadAndBadOnesAreSkipped() throws {
        let folder = try Folder()
        var faces: [String: JSONValue] = [:]
        for index in 0..<10 { faces["Face \(index)"] = Self.file(try folder.write(Self.woff2, "f\(index).woff2")) }
        faces["Face 0:bold"] = .string("file:/nope.woff2")
        // Key order: "Face 0", "Face 0:bold" (bad), "Face 1" ... "Face 6" are the first eight.
        let loaded = ChatFontFaces.Loader().dataURLs(faces)
        #expect(loaded.keys.sorted() == (0...6).map { "Face \($0)" })
    }

    /// A read is cached by path, size and modification time: a changed file gives its new bytes.
    @Test func aChangedFileIsReadAgain() throws {
        let folder = try Folder()
        let path = try folder.write(Self.woff2, "x.woff2")
        let loader = ChatFontFaces.Loader()
        let first = loader.dataURLs(["A": Self.file(path)])["A"]
        #expect(first != nil)
        #expect(loader.dataURLs(["A": Self.file(path)])["A"] == first)
        let changed = Self.woff2 + Data("more".utf8)
        try folder.write(changed, "x.woff2")
        #expect(loader.dataURLs(["A": Self.file(path)])["A"] == "data:font/woff2;base64," + changed.base64EncodedString())
    }

    /// The page gets `{family[:italic]: data URL}` at the setting's key, and the family rows as written.
    @Test func thePageGetsTheFacesAsDataURLs() throws {
        let folder = try Folder()
        let path = try folder.write(Self.woff2, "Pack.woff2")
        let root: JSONValue = ["agentPane": ["display": ["font": [
            "uiFamily": "Pack Sans, system-ui", "proseFamily": "Pack Serif",
            "faces": ["Pack Sans": Self.file(path), "Bad, Key": Self.file(path)],
        ]]]]
        let values = AgentPaneDisplaySetting(fileRoot: root, fontFaces: ChatFontFaces.Loader()).values
        #expect(values["agentPane.display.font.uiFamily"] == "Pack Sans, system-ui")
        #expect(values["agentPane.display.font.proseFamily"] == "Pack Serif")
        #expect(values["agentPane.display.font.faces"] == .object(["Pack Sans": .string("data:font/woff2;base64," + Self.woff2.base64EncodedString())]))
        let none: JSONValue = ["agentPane": ["display": ["font": ["faces": ["A": "file:/nope.woff2"]]]]]
        #expect(AgentPaneDisplaySetting(fileRoot: none, fontFaces: ChatFontFaces.Loader()).values["agentPane.display.font.faces"] == nil)
        // With no loader (the palette's rail toggles) no face file is read and the key is left out.
        #expect(AgentPaneDisplaySetting(fileRoot: root).values["agentPane.display.font.faces"] == nil)
    }

    /// A theme file may set the chat's typography, and its face files resolve against the themes
    /// folder as pictures do (`file:../fonts/x.woff2`).
    @Test func aThemeFileSetsTheChatTypographyAndItsFacesResolveAgainstTheThemesFolder() {
        let folder = URL(fileURLWithPath: "/tmp/cmux-config/themes", isDirectory: true)
        let text = #"""
        { "agentPane.display.font.uiFamily": "Pack Sans, system-ui", "agentPane.display.font.proseFamily": "Pack Serif",
          "agentPane.display.code.family": "Pack Mono", "agentPane.display.code.scale": 0.8,
          "agentPane.display.font.faces": { "Pack Sans": "file:../fonts/PackSans.woff2", "Pack Serif:italic": "file:/Library/Fonts/P.otf" } }
        """#
        let overlay = ThemeFileOverlay(name: "pack", source: .success(text), base: .object([:]), folder: folder)
        #expect(overlay.diagnostics.isEmpty, "\(overlay.diagnostics)")
        #expect(overlay.values.map { $0.path.joined(separator: ".") } == [
            "agentPane.display.code.family", "agentPane.display.code.scale", "agentPane.display.font.faces",
            "agentPane.display.font.proseFamily", "agentPane.display.font.uiFamily",
        ])
        #expect(overlay.applied(to: .object([:])).value(at: AgentPaneDisplaySettingsSchema.facesPath) == .object([
            "Pack Sans": "file:/tmp/cmux-config/fonts/PackSans.woff2", "Pack Serif:italic": "file:/Library/Fonts/P.otf",
        ]))
        // A chat key that is no look is still refused.
        let other = ThemeFileOverlay(name: "pack", source: .success(#"{ "agentPane.display.minimap": "off" }"#), base: .object([:]))
        #expect(other.diagnostics.map(\.path) == ["agentPane.display.minimap"])
    }

    /// The installed theme's values reach the chat: the person's file stays theirs (``fileRoot``),
    /// and the chat reads it with the theme file over it (``fileRootWithThemeFile``).
    @MainActor @Test func anActiveThemeFilesFontsReachTheChat() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let fonts = home.url.appending(path: "fonts/theme-alice-pack")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Self.woff2.write(to: fonts.appending(path: "Pack.woff2"))
        try home.write(#"""
        { "agentPane.display.font.uiFamily": "Pack Sans", "agentPane.display.font.faces": { "Pack Sans": "file:../fonts/theme-alice-pack/Pack.woff2" } }
        """#, theme: "pack")
        let settings = try ThemeFileTests.controller(home, config: #"{ "appearance": { "themeFile": "pack" }, "agentPane": { "display": { "font": { "size": 16 } } } }"#)
        await settings.reload()
        #expect(settings.fileRoot.value(at: AgentPaneDisplaySettingsSchema.uiFamilyPath) == nil)
        let values = AgentPaneDisplaySetting(fileRoot: settings.chatDisplayInputs.root, fontFaces: ChatFontFaces.Loader()).values
        #expect(values["agentPane.display.font.uiFamily"] == "Pack Sans")
        #expect(values["agentPane.display.font.size"] == .number(16))
        #expect(values["agentPane.display.font.faces"] == .object(["Pack Sans": .string("data:font/woff2;base64," + Self.woff2.base64EncodedString())]))
    }
}
