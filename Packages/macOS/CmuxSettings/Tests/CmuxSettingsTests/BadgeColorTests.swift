import Foundation
import Testing
@testable import CmuxSettings

/// Behavior of ``BadgeColor/init(parsing:)`` and ``BadgeColor/hexString``:
/// resolving the `badge.color` string (a SwiftUI system color name or a
/// `#RRGGBB` hex) to sRGB components, and reversing components back to hex.
@Suite("BadgeColor")
struct BadgeColorTests {
    @Test func parsesHexWithHash() {
        let color = BadgeColor(parsing: "#FF8800")
        #expect(color?.red == 1)
        #expect(color?.green == Double(0x88) / 255)
        #expect(color?.blue == 0)
    }

    @Test func parsesHexWithoutHash() {
        #expect(BadgeColor(parsing: "00FF00") == BadgeColor(red: 0, green: 1, blue: 0))
    }

    @Test func parsesKnownNameCaseInsensitively() {
        #expect(BadgeColor(parsing: "GREEN") == BadgeColor.namedColors["green"])
        #expect(BadgeColor(parsing: "Blue") == BadgeColor.namedColors["blue"])
    }

    @Test func greyIsAnAliasForGray() {
        #expect(BadgeColor(parsing: "grey") == BadgeColor(parsing: "gray"))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(BadgeColor(parsing: "  red  ") == BadgeColor.namedColors["red"])
        #expect(BadgeColor(parsing: " #010203 ") == BadgeColor(parsing: "#010203"))
    }

    @Test func emptyStringIsNil() {
        #expect(BadgeColor(parsing: "") == nil)
        #expect(BadgeColor(parsing: "   ") == nil)
    }

    @Test func unknownNameIsNil() {
        #expect(BadgeColor(parsing: "chartreuse") == nil)
    }

    @Test func malformedHexIsNil() {
        #expect(BadgeColor(parsing: "#FFF") == nil)        // too short
        #expect(BadgeColor(parsing: "#GGGGGG") == nil)     // non-hex digits
        #expect(BadgeColor(parsing: "#FF88001") == nil)    // too long
    }

    @Test func hexStringRoundTripsHexInput() {
        let color = BadgeColor(parsing: "#1A2B3C")
        #expect(color?.hexString == "#1A2B3C")
    }

    @Test func hexStringIsUppercased() {
        #expect(BadgeColor(parsing: "ffaa00")?.hexString == "#FFAA00")
    }

    @Test func namesExcludeGreyAliasAndAreSorted() {
        let names = BadgeColor.names
        #expect(!names.contains("grey"))
        #expect(names.contains("gray"))
        #expect(names == names.sorted())
        // Every advertised name resolves.
        for name in names {
            #expect(BadgeColor(parsing: name) != nil)
        }
    }
}
