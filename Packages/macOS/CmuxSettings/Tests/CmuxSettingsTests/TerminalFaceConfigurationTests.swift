import Testing
@testable import CmuxSettings

@Suite("Terminal face configuration")
struct TerminalFaceConfigurationTests {
    @Test func roundTripsEveryCustomization() {
        var expected = TerminalFaceConfiguration.default
        expected.enabled = true
        expected.animation = .always
        expected.opacity = 0.72
        expected.scale = 0.44
        expected.horizontalPosition = 0.2
        expected.errorColor = "#123ABC"

        let decoded = TerminalFaceConfiguration.decodeFromJSON(expected.encodeForJSON())

        #expect(decoded == expected)
    }

    @Test func sanitizesBoundsAndColors() {
        var raw = TerminalFaceConfiguration.default.encodeForJSON() as! [String: Any]
        raw["opacity"] = 4.0
        raw["scale"] = 0.01
        raw["horizontalPosition"] = -2.0
        raw["idleColor"] = "not-a-color"

        let decoded = TerminalFaceConfiguration.decodeFromJSON(raw)

        #expect(decoded?.opacity == 1)
        #expect(decoded?.scale == 0.25)
        #expect(decoded?.horizontalPosition == 0)
        #expect(decoded?.idleColor == TerminalFaceConfiguration.default.idleColor)
    }

    @Test func catalogDefaultsToDisabled() {
        let key = SettingCatalog().terminal.face
        #expect(key.id == "terminal.face")
        #expect(key.defaultValue.enabled == false)
        #expect(key.defaultValue.reactsToAgents == true)
    }
}
