import CmuxSyntaxHighlighting
import Foundation
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("Highlight color remapper")
struct HighlightColorRemapperTests {
    @Test("Xcode-dark magenta becomes cmux product blue")
    func remapsXcodeDarkKeyword() throws {
#if canImport(AppKit)
        let source = NSMutableAttributedString(string: "func")
        let xcodeKeyword = NSColor(
            red: 252.0 / 255.0,
            green: 95.0 / 255.0,
            blue: 163.0 / 255.0,
            alpha: 1
        )
        source.addAttribute(
            .foregroundColor,
            value: xcodeKeyword,
            range: NSRange(location: 0, length: source.length)
        )

        let remapped = HighlightColorRemapper(theme: .dark).remap(source)
        let color = remapped.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        )
        let hex = try #require(HighlightColorRemapper.hexKey(from: color as Any))
        #expect(hex == "0091FF")
#else
        Issue.record("Remapper tests require AppKit")
#endif
    }

    @Test("Xcode light keyword becomes readable product blue")
    func remapsXcodeLightKeyword() throws {
#if canImport(AppKit)
        let source = NSMutableAttributedString(string: "func")
        let xcodeKeyword = NSColor(
            red: 170.0 / 255.0,
            green: 13.0 / 255.0,
            blue: 145.0 / 255.0,
            alpha: 1
        )
        source.addAttribute(
            .foregroundColor,
            value: xcodeKeyword,
            range: NSRange(location: 0, length: source.length)
        )

        let remapped = HighlightColorRemapper(theme: .light).remap(source)
        let color = remapped.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        )
        let hex = try #require(HighlightColorRemapper.hexKey(from: color as Any))
        #expect(hex == "006DC1")
#else
        Issue.record("Remapper tests require AppKit")
#endif
    }

    @Test("Hex keys retain rounding compatibility")
    func hexKeysRoundLikeThePublicFormatter() {
        #expect(
            HighlightColorRemapper.hexKey(
                red: 252.49 / 255.0,
                green: 94.51 / 255.0,
                blue: 162.5 / 255.0
            ) == "FC5FA3"
        )
        #expect(
            HighlightColorRemapper.hexKey(
                red: -1,
                green: 2,
                blue: 0
            ) == "00FF00"
        )
    }

    @Test("Explicit source maps retain public hex-key compatibility")
    func explicitSourceMapRemapsMatchingColor() throws {
#if canImport(AppKit)
        let source = NSMutableAttributedString(string: "token")
        source.addAttribute(
            .foregroundColor,
            value: NSColor(
                red: 252.0 / 255.0,
                green: 95.0 / 255.0,
                blue: 163.0 / 255.0,
                alpha: 1
            ),
            range: NSRange(location: 0, length: source.length)
        )
        let remapper = HighlightColorRemapper(
            palette: .cmuxDark,
            sourceMap: ["FC5FA3": .keyword]
        )

        let remapped = remapper.remap(source)
        let color = remapped.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(HighlightColorRemapper.hexKey(from: color as Any) == "0091FF")
#else
        Issue.record("Remapper tests require AppKit")
#endif
    }

    @Test("Source-map lookup retains uppercase hex-key matching")
    func sourceMapLookupRemainsCaseSensitive() throws {
#if canImport(AppKit)
        let source = NSMutableAttributedString(string: "token")
        source.addAttribute(
            .foregroundColor,
            value: NSColor(
                red: 252.0 / 255.0,
                green: 95.0 / 255.0,
                blue: 163.0 / 255.0,
                alpha: 1
            ),
            range: NSRange(location: 0, length: source.length)
        )
        let remapper = HighlightColorRemapper(
            palette: .cmuxDark,
            sourceMap: ["fc5fa3": .keyword]
        )

        let remapped = remapper.remap(source)
        let color = remapped.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(HighlightColorRemapper.hexKey(from: color as Any) == "FC5FA3")
#else
        Issue.record("Remapper tests require AppKit")
#endif
    }

    @Test("Engine JSON tokens use the cmux palette, not Xcode pink")
    func enginePaintsBrandColors() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = """
        {
          "name": "cmux",
          "count": 3,
          "enabled": true
        }
        """
        let highlighted = try #require(
            await engine.highlight(text: source, language: "json", theme: .dark)
        )
        let ns = highlighted.value.string as NSString

        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        let trueHex = hex(in: highlighted.value, at: trueRange.location)
        #expect(trueHex == "0091FF")

        let stringRange = ns.range(of: "\"cmux\"")
        #expect(stringRange.location != NSNotFound)
        let stringHex = hex(in: highlighted.value, at: stringRange.location + 1)
        #expect(stringHex == "E0B86A")

        let numberRange = ns.range(of: "3")
        #expect(numberRange.location != NSNotFound)
        let numberHex = hex(in: highlighted.value, at: numberRange.location)
        #expect(numberHex == "5ED0C8")

        #expect(!containsHex(highlighted.value, "FC5FA3"))
        #expect(!containsHex(highlighted.value, "FC6A5D"))
    }

    @Test("Engine light JSON tokens use readable product blue")
    func engineLightPaintsBrandColors() async throws {
        let engine = HighlightrSyntaxEngine()
        let source = #"{ "enabled": true }"#
        let highlighted = try #require(
            await engine.highlight(text: source, language: "json", theme: .light)
        )
        let ns = highlighted.value.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        let trueHex = hex(in: highlighted.value, at: trueRange.location)
        #expect(trueHex == "006DC1")
        #expect(!containsHex(highlighted.value, "AA0D91"))
    }

    private func hex(in string: NSAttributedString, at location: Int) -> String? {
        let color = string.attribute(.foregroundColor, at: location, effectiveRange: nil)
        return HighlightColorRemapper.hexKey(from: color as Any)
    }

    private func containsHex(_ string: NSAttributedString, _ hex: String) -> Bool {
        let full = NSRange(location: 0, length: string.length)
        var found = false
        string.enumerateAttribute(.foregroundColor, in: full, options: []) { value, _, stop in
            guard let value, HighlightColorRemapper.hexKey(from: value) == hex else { return }
            found = true
            stop.pointee = true
        }
        return found
    }
}
