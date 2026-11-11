@testable import CmuxNextSettings
import Testing

/// `browser.vimKeys`: the page letters (f, F, j, k, gg, G) are on unless cmux.json turns them off.
struct BrowserVimKeysSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onWhenUnset() {
        #expect(Self.snapshot(.object([:])).browserVimKeys)
        #expect(Self.snapshot(.object(["browser": .object([:])])).browserVimKeys)
    }

    @Test func offWhenFalse() {
        let off = Self.snapshot(.object(["browser": .object(["vimKeys": .bool(false)])]))
        #expect(!off.browserVimKeys)
        #expect(off.diagnostics.isEmpty)
    }

    @Test func aNonBoolIsOnWithADiagnostic() {
        let bad = Self.snapshot(.object(["browser": .object(["vimKeys": .string("no")])]))
        #expect(bad.browserVimKeys)
        #expect(bad.diagnostics.contains { $0.path == "browser.vimKeys" })
    }
}
