import Foundation
import Testing
@testable import CmuxSettings

@Suite("SettingCodable")
struct SettingCodableTests {
    @Test func boolDecodesFromNSNumberBoolean() {
        #expect(Bool.decodeFromUserDefaults(NSNumber(value: true)) == true)
        // JSON keeps the bool/int distinction; UserDefaults does not.
        #expect(Bool.decodeFromJSON(NSNumber(value: 1)) == nil)
    }

    @Test func intDistinguishesBooleanFromIntInJSON() {
        #expect(Int.decodeFromJSON(NSNumber(value: true)) == nil)
        #expect(Int.decodeFromJSON(NSNumber(value: 42)) == 42)
    }

    @Test func intFromJSONRejectsFractional() {
        #expect(Int.decodeFromJSON(NSNumber(value: 1.5)) == nil)
        #expect(Int.decodeFromJSON(NSNumber(value: 7)) == 7)
    }

    @Test func rawRepresentableEnumRoundTrips() {
        let encoded = AppearanceMode.dark.encodeForJSON()
        #expect(encoded as? String == "dark")
        #expect(AppearanceMode.decodeFromJSON(encoded) == .dark)
    }

    @Test func arrayRoundTrip() {
        let value: [String] = ["a", "b"]
        let encoded = value.encodeForJSON()
        #expect([String].decodeFromJSON(encoded) == value)
    }

    @Test func dictionaryRoundTrip() {
        let value: [String: Int] = ["x": 1, "y": 2]
        let encoded = value.encodeForJSON()
        #expect([String: Int].decodeFromJSON(encoded) == value)
    }
}
