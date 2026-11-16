import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.fontSmoothing`, the CSS model: `auto` (the default: the Mac's own smoothing for native
/// text, each page's own style for web text, the look cmux had before the setting), `antialiased`
/// (thin, grayscale) and `subpixel` (macOS font smoothing on). The first release's `system` reads
/// as `auto`; a bad value keeps the default and says why.
struct FontSmoothingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["fontSmoothing": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func autoByDefaultSoNothingChangesUntilThePersonPicks() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test(arguments: ["auto", "antialiased", "subpixel"])
    func eachCSSValueIsAChoice(_ value: String) {
        let snapshot = Self.parse(.string(value))
        #expect(snapshot.fontSmoothing.rawValue == value)
        #expect(snapshot.diagnostics.isEmpty, "\(value): \(snapshot.diagnostics)")
    }

    @Test func theFirstReleasesSystemValueReadsAsAuto() {
        let snapshot = Self.parse(.string("system"))
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test(arguments: [JSONValue.string("subpixel-antialiased-ish"), .bool(true), .number(0)])
    func aBadValueKeepsTheDefaultAndSaysWhy(_ value: JSONValue) {
        let snapshot = Self.parse(value)
        #expect(snapshot.fontSmoothing.rawValue == "auto")
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.fontSmoothing" }, "\(snapshot.diagnostics)")
    }
}
