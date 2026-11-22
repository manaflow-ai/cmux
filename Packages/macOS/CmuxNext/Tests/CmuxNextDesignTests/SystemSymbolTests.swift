import AppKit
import CmuxNextDesign
import Foundation
import Testing

/// SF Symbols the macOS app draws. macOS 27.3 aborts at launch when AppKit is asked for a configured variant of a
/// symbol its public catalog lacks ("NSImage requested a variant from a symbol that wasn't found in the asset
/// catalog"): the compose bar drew Messages' private `emoji.face.grinning` from `CoreGlyphsPrivate.bundle`.
@Suite struct SystemSymbolTests {
    @Test func publicSymbolResolvesItself() {
        #expect(NSImage.isSystemSymbol("face.smiling.inverse"))
        #expect(NSImage.systemSymbol("face.smiling.inverse", fallback: nil) != nil)
    }

    @Test func missingOrPrivateNameFallsBack() throws {
        // A private symbol (CoreGlyphsPrivate) is not a public one, nor is a misspelled or empty name.
        for name in ["emoji.face.grinning", "sticker.badge.plus", "not.a.real.symbol", ""] {
            #expect(!NSImage.isSystemSymbol(name), "\(name)")
            #expect(NSImage.systemSymbol(name, fallback: nil) == nil, "\(name)")
            let fallback = try #require(NSImage.systemSymbol(name), "\(name)")
            let expected = try #require(NSImage(systemSymbolName: NSImage.fallbackSymbolName, accessibilityDescription: nil))
            #expect(fallback.size == expected.size, "\(name)")
        }
        #expect(NSImage.isSystemSymbol(NSImage.fallbackSymbolName))
    }

    @Test func configuredFallbackDrawsInk() throws {
        let image = try #require(NSImage.systemSymbol("emoji.face.grinning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        let inked = (0..<40).contains { x in (0..<40).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 } }
        #expect(inked)
    }

    /// Every symbol name the macOS app's sources pass to a symbol API as a literal is in this Mac's public catalog,
    /// and no source loads a symbol from a system glyph bundle.
    @Test func everyLiteralSymbolNameResolves() throws {
        let files = Self.sourceRoots.flatMap(Self.swiftFiles)
        #expect(files.count > 500, "found \(files.count) Swift files under \(Self.sourceRoots.map(\.path))")
        // `systemSymbolName: "x"`, `Image(systemName: "x")`, `Label(_, systemImage: "x")`, `symbol: "x"`; not `.symbol: "x"`.
        let call = try NSRegularExpression(
            pattern: #"(?<![.\w])(?:systemSymbolName|systemName|systemImage|symbolName|symbol)\s*:\s*"([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
        var missing: [String] = []
        var privateLoads: [String] = []
        var checked = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: Self.repoRoot.path + "/", with: "")
            if text.contains("CoreGlyphsPrivate.bundle\"") { privateLoads.append(relative) }
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                checked += 1
                let name = String(text[range])
                if !NSImage.isSystemSymbol(name) { missing.append("\(relative): \(name)") }
            }
        }
        #expect(checked > 300, "checked \(checked) literal symbol names")
        #expect(missing.isEmpty, "not in this Mac's public SF Symbols catalog:\n\(missing.joined(separator: "\n"))")
        #expect(privateLoads.isEmpty, "loads a private glyph bundle:\n\(privateLoads.joined(separator: "\n"))")
    }

    /// Tests/CmuxNextDesignTests/SystemSymbolTests.swift -> the repository root.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Packages/macOS/CmuxNext
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Swift sources linked into the macOS app, named as file patterns: the CI router reads each pattern as
    /// "a changed .swift file here selects this suite", where a bare folder would also select it for a web bundle
    /// or a resource under the same folder (Resources/agent-pane/index.html), which it never reads.
    static let sourcePatterns = [
        "Packages/macOS/CmuxNext/Sources/**/*.swift",
        "Packages/Shared/CmuxMessagesLab/Sources/**/*.swift",
        "Packages/Shared/CmuxScreenKit/Sources/**/*.swift",
        "Packages/iOS/CmuxConversation/Sources/CmuxConversationMacUI/**/*.swift",
    ]
    static let sourceRoots = sourcePatterns.map {
        repoRoot.appendingPathComponent(String($0.dropLast("/**/*.swift".count)), isDirectory: true)
    }

    static func swiftFiles(under root: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
