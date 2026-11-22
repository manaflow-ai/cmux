import Testing
@testable import CmuxNextSettings

/// `browser.hibernation` in cmux.json (plans/cmux-next/tab-lifecycle.md).
struct BrowserHibernationSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToModerateWithoutDiagnostics() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.browserHibernation == .fallback)
        #expect(snapshot.browserHibernation.hiddenMinutes == 60)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func parsesEveryMode() throws {
        #expect(try parse(#"{"browser": {"hibernation": "off"}}"#).browserHibernation.mode == .off)
        #expect(try parse(#"{"browser": {"hibernation": "off"}}"#).browserHibernation.hiddenMinutes == nil)
        #expect(try parse(#"{"browser": {"hibernation": "aggressive"}}"#).browserHibernation.hiddenMinutes == 10)
        #expect(try parse(#"{"browser": {"hibernation": 25}}"#).browserHibernation.mode == .minutes(25))
    }

    @Test func aBadValueKeepsTheDefaultAndReportsIt() throws {
        for bad in [#""sometimes""#, "0", "-3", "true"] {
            let snapshot = try parse(#"{"browser": {"hibernation": \#(bad)}}"#)
            #expect(snapshot.browserHibernation.mode == .moderate)
            #expect(snapshot.diagnostics.map(\.path) == ["browser.hibernation"])
        }
    }

    @Test func exclusionsMatchHostsAndSubdomains() throws {
        let setting = try parse(#"{"browser": {"hibernationExclusions": ["example.com", "*.example.org"], "hibernatePinnedTabs": true}}"#)
            .browserHibernation
        #expect(setting.includesPinnedTabs)
        #expect(setting.excludes(host: "example.com"))
        #expect(setting.excludes(host: "mail.EXAMPLE.com"))
        #expect(!setting.excludes(host: "notexample.com"))
        #expect(setting.excludes(host: "www.example.org"))
        #expect(!setting.excludes(host: "example.org"))
        #expect(!setting.excludes(host: nil))
    }

    @Test func configValueRoundTrips() throws {
        for mode in [BrowserHibernationSetting.Mode.off, .moderate, .aggressive, .minutes(15)] {
            let value = BrowserHibernationSetting(mode: mode).configValue
            let snapshot = CmuxConfigSnapshot.parse(.object(["browser": .object(["hibernation": value])]), validDensities: [], validMetrics: [])
            #expect(snapshot.browserHibernation.mode == mode)
        }
    }
}
