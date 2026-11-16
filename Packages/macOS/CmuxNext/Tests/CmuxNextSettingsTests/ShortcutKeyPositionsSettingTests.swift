@testable import CmuxNextSettings
import Testing

/// `shortcuts.keyPositions`: shortcuts follow the typed letter unless cmux.json asks for QWERTY positions.
struct ShortcutKeyPositionsSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    private static func positions(_ value: JSONValue) -> CmuxConfigSnapshot {
        snapshot(.object(["shortcuts": .object(["keyPositions": value])]))
    }

    @Test func typedWhenUnset() {
        #expect(!Self.snapshot(.object([:])).shortcutQwertyPositions)
        #expect(!Self.positions(.string("typed")).shortcutQwertyPositions)
    }

    @Test func qwertyWhenSet() {
        let qwerty = Self.positions(.string("qwerty"))
        #expect(qwerty.shortcutQwertyPositions)
        #expect(qwerty.diagnostics.isEmpty)
    }

    @Test func anUnknownValueIsTypedWithADiagnostic() {
        let bad = Self.positions(.string("dvorak"))
        #expect(!bad.shortcutQwertyPositions)
        #expect(bad.diagnostics.contains { $0.path == "shortcuts.keyPositions" })
    }

    /// Not an action id: no unknown-action diagnostic and no binding named keyPositions.
    @Test func isNotAnActionBinding() {
        let qwerty = Self.positions(.string("qwerty"))
        #expect(qwerty.shortcuts["keyPositions"] == nil)
        #expect(!qwerty.diagnostics.contains { $0.path.contains("keyPositions") })
    }
}
