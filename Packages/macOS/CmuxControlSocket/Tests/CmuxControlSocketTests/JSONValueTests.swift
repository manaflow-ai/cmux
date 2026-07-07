import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("JSONValue bridging")
struct JSONValueTests {
    @Test func bridgesJSONSerializationOutputLosslessly() throws {
        let line = """
        {"s":"hi","i":5,"d":1.5,"b":true,"f":false,"n":null,"a":[1,"two",{"k":false}],"o":{"x":-9}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let value = try #require(JSONValue(foundationObject: object))
        #expect(value == .object([
            "s": .string("hi"),
            "i": .int(5),
            "d": .double(1.5),
            "b": .bool(true),
            "f": .bool(false),
            "n": .null,
            "a": .array([.int(1), .string("two"), .object(["k": .bool(false)])]),
            "o": .object(["x": .int(-9)]),
        ]))
    }

    @Test func distinguishesBoolsFromNumbers() {
        #expect(JSONValue(foundationObject: true) == .bool(true))
        #expect(JSONValue(foundationObject: NSNumber(value: false)) == .bool(false))
        #expect(JSONValue(foundationObject: 1) == .int(1))
        #expect(JSONValue(foundationObject: NSNumber(value: 0)) == .int(0))
    }

    @Test func integralDoublesStayDoubles() {
        // JSON `5.0` parses as a double NSNumber; the legacy params dict kept
        // it floating-point, so the bridge must not coerce it to int.
        #expect(JSONValue(foundationObject: NSNumber(value: 5.0)) == .double(5.0))
    }

    @Test func bridgesSwiftNativeValues() {
        #expect(JSONValue(foundationObject: "x") == .string("x"))
        #expect(JSONValue(foundationObject: Int64(7)) == .int(7))
        #expect(JSONValue(foundationObject: 2.25) == .double(2.25))
        #expect(JSONValue(foundationObject: NSNull()) == .null)
        #expect(JSONValue(foundationObject: ["a", 1] as [Any]) == .array([.string("a"), .int(1)]))
        #expect(JSONValue(foundationObject: ["k": true] as [String: Any]) == .object(["k": .bool(true)]))
    }

    @Test func rejectsNonJSONValues() {
        #expect(JSONValue(foundationObject: UUID()) == nil)
        #expect(JSONValue(foundationObject: ["k": UUID()] as [String: Any]) == nil)
        #expect(JSONValue(foundationObject: [Date()] as [Any]) == nil)
    }

    @Test func unsignedNumbersBeyondInt64BecomeDoubles() {
        #expect(JSONValue(foundationObject: NSNumber(value: UInt64.max)) == .double(NSNumber(value: UInt64.max).doubleValue))
        #expect(JSONValue(foundationObject: NSNumber(value: UInt64(Int64.max))) == .int(Int64.max))
    }

    @Test func foundationRoundTripPreservesSerialization() throws {
        let line = """
        {"s":"a\\nb","i":5,"d":1.5,"b":true,"n":null,"a":[1,2],"o":{"k":"v"}}
        """
        let original = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let bridged = try #require(JSONValue(foundationObject: original)).foundationObject
        let originalData = try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        let bridgedData = try JSONSerialization.data(withJSONObject: bridged, options: [.sortedKeys])
        #expect(originalData == bridgedData)
    }
}
