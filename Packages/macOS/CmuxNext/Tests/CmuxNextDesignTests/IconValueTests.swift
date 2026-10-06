import CmuxNextDesign
import Testing

/// The one icon value (R94): the wire string of every object's `icon` field
/// decodes the same way everywhere, and matches the page's iconValue.ts.
struct IconValueTests {
    static let digest = String(repeating: "a", count: 64)

    @Test func wireRoundTrip() {
        let values: [IconValue] = [.emoji("👍🏽"), .emoji("🇯🇵"), .emoji("👩‍💻"), .emoji("1️⃣"), .symbol("star.fill"),
                                   .symbol("1.circle"), .image("sha256-" + Self.digest), .svg("sha256-" + Self.digest)]
        for value in values {
            #expect(IconValue(wire: value.wire) == value)
        }
        #expect(IconValue(wire: "image:sha256-" + Self.digest) == .image("sha256-" + Self.digest))
    }

    @Test func refusals() {
        for bad in ["", "🚀🚀", "a b", "House", "star.", ".star", "star..fill", "image:sha256-xyz", "svg:../etc",
                    "image:" + Self.digest, "😀a"] {
            #expect(IconValue(wire: bad) == nil, "\(bad)")
        }
        #expect(IconValue(wire: nil) == nil)
        #expect(IconValue(wire: "a") == .symbol("a"))
    }

    @Test func emojiRule() {
        #expect(IconValue.isEmoji("🚀") && IconValue.isEmoji("❤️") && IconValue.isEmoji("👨‍👩‍👧‍👦"))
        #expect(!IconValue.isEmoji("a") && !IconValue.isEmoji("1") && !IconValue.isEmoji("©"))
        #expect(!IconValue.isEmoji(String(repeating: "\u{1F468}\u{200D}", count: 8) + "\u{1F468}"))
    }
}
