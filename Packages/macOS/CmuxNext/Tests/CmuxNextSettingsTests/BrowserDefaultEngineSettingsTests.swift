import CmuxNextSettings
import Testing

/// `browser.defaultEngine`: Chromium unless the file says WebKit; a bad
/// value keeps Chromium and reports a diagnostic.
@Suite struct BrowserDefaultEngineSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToChromium() throws {
        #expect(try parse("{}").browserDefaultEngine == .chromium)
        #expect(try parse(#"{"browser": {"other": 1}}"#).browserDefaultEngine == .chromium)
        #expect(try parse("{}").diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.browserDefaultEngine == .chromium)
    }

    @Test func readsBothEngines() throws {
        #expect(try parse(#"{"browser": {"defaultEngine": "webkit"}}"#).browserDefaultEngine == .webkit)
        #expect(try parse(#"{"browser": {"defaultEngine": "chromium"}}"#).browserDefaultEngine == .chromium)
    }

    @Test func badValuesKeepChromiumWithADiagnostic() throws {
        for text in [#"{"browser": {"defaultEngine": "safari"}}"#, #"{"browser": {"defaultEngine": 1}}"#, #"{"browser": "webkit"}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.browserDefaultEngine == .chromium, "\(text)")
            #expect(snapshot.diagnostics.map(\.kind) == [.invalidValue], "\(text)")
        }
        #expect(try parse(#"{"browser": {"defaultEngine": "safari"}}"#).diagnostics.first?.path == "browser.defaultEngine")
    }
}
