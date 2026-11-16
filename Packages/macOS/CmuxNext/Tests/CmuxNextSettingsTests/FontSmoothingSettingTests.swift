import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.fontSmoothing`: thin (antialiased) by default, so native text matches the web UI;
/// `system` keeps the Mac's own smoothing; a bad value keeps the default and says why.
struct FontSmoothingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["fontSmoothing": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func thinByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.fontSmoothing == .antialiased)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func thePersonCanKeepTheSystemLook() {
        #expect(Self.parse(.string("system")).fontSmoothing == .system)
        #expect(Self.parse(.string("antialiased")).fontSmoothing == .antialiased)
    }

    @Test(arguments: [JSONValue.string("subpixel"), .bool(true), .number(0)])
    func aBadValueKeepsTheDefaultAndSaysWhy(_ value: JSONValue) {
        let snapshot = Self.parse(value)
        #expect(snapshot.fontSmoothing == .antialiased)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.fontSmoothing" }, "\(snapshot.diagnostics)")
    }
}
