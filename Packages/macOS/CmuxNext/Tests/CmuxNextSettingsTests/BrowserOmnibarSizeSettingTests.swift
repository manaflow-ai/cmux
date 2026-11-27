import CmuxNextSettings
import Testing

/// `browser.omnibar.height` and `browser.omnibar.fontSize` (https://github.com/manaflow-ai/cmux/issues/28734):
/// unset or `"density"` follows density; a number in range sets it; a number past the range applies
/// at the nearest end with a diagnostic; anything else keeps density and says so.
@MainActor struct BrowserOmnibarSizeSettingTests {
    static func parse(height: JSONValue? = nil, fontSize: JSONValue? = nil) -> CmuxConfigSnapshot {
        var omnibar: [String: JSONValue] = [:]
        if let height { omnibar["height"] = height }
        if let fontSize { omnibar["fontSize"] = fontSize }
        return CmuxConfigSnapshot.parse(.object(["browser": .object(["omnibar": .object(omnibar)])]), validDensities: [], validMetrics: [])
    }

    @Test func unsetFollowsDensityWithSettingsRows() {
        let snapshot = Self.parse()
        #expect(snapshot.browserOmnibar.height == nil && snapshot.browserOmnibar.fontSize == nil)
        #expect(snapshot.diagnostics.isEmpty)
        for key in ["height", "fontSize"] {
            let row = SettingsSchema.descriptor(for: ["browser", "omnibar", key])
            #expect(row != nil, "a Settings row (and a palette row) for browser.omnibar.\(key)")
            #expect(row?.defaultValue == .string("density"))
            #expect(SettingsSchema.agentSettableKeys.contains("browser.omnibar.\(key)"), "looks only")
        }
    }

    @Test func densityWordFollowsDensity() {
        let snapshot = Self.parse(height: .string("density"), fontSize: .string("density"))
        #expect(snapshot.browserOmnibar.height == nil && snapshot.browserOmnibar.fontSize == nil)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func numbersInRangeApply() {
        let snapshot = Self.parse(height: .number(36), fontSize: .number(16))
        #expect(snapshot.browserOmnibar.height == 36)
        #expect(snapshot.browserOmnibar.fontSize == 16)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func numbersPastTheRangeAreClampedAndReported() {
        let high = Self.parse(height: .number(200), fontSize: .number(80))
        #expect(high.browserOmnibar.height == BrowserOmnibarSetting.heightRange.upperBound)
        #expect(high.browserOmnibar.fontSize == BrowserOmnibarSetting.fontSizeRange.upperBound)
        #expect(high.diagnostics.contains { $0.path == "browser.omnibar.height" })
        #expect(high.diagnostics.contains { $0.path == "browser.omnibar.fontSize" })
        let low = Self.parse(height: .number(2), fontSize: .number(1))
        #expect(low.browserOmnibar.height == BrowserOmnibarSetting.heightRange.lowerBound)
        #expect(low.browserOmnibar.fontSize == BrowserOmnibarSetting.fontSizeRange.lowerBound)
    }

    @Test func otherValuesKeepDensityAndSaySo() {
        for bad: JSONValue in [.string("big"), .bool(true)] {
            let snapshot = Self.parse(height: bad, fontSize: bad)
            #expect(snapshot.browserOmnibar.height == nil && snapshot.browserOmnibar.fontSize == nil)
            #expect(snapshot.diagnostics.contains { $0.path == "browser.omnibar.height" })
            #expect(snapshot.diagnostics.contains { $0.path == "browser.omnibar.fontSize" })
        }
    }

    /// Settings never writes a value that loads with a warning: the row refuses what the parser clamps.
    @Test func theRowAcceptsWhatTheParserAppliesWithoutAWarning() throws {
        let row = try #require(SettingsSchema.descriptor(for: BrowserOmnibarSetting.fontSizePath))
        #expect(row.accepts(.string("density")))
        #expect(row.accepts(.number(15)))
        #expect(!row.accepts(.number(80)))
        #expect(!row.accepts(.string("big")))
    }
}
