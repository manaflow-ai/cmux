import CmuxNextCompat
import Foundation
import Testing

/// ``CheckedJSON`` (p10-stability-166/167): every object `JSONSerialization.data(withJSONObject:)`
/// would raise an Objective-C exception for (the process ends; Swift cannot catch it) throws
/// ``CheckedJSONError/invalidJSONObject(topLevelType:)`` instead, and a valid object writes the
/// same bytes `JSONSerialization` writes.
@Suite struct CheckedJSONTests {
    @Test func aValidObjectWritesTheBytesJSONSerializationWrites() throws {
        let object: [String: Any] = ["b": 1, "a": ["x", 2.5, true, NSNull()], "c": ["k": "v/w"]]
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let checked = try CheckedJSON.data(withJSONObject: object, options: options)
        #expect(checked == (try JSONSerialization.data(withJSONObject: object, options: options)))
        #expect(String(decoding: checked, as: UTF8.self) == #"{"a":["x",2.5,true,null],"b":1,"c":{"k":"v/w"}}"#)
    }

    @Test func aValueJSONCannotHoldThrowsInsteadOfRaising() {
        let objects: [[String: Any]] = [
            ["at": Date(timeIntervalSince1970: 0)],
            ["url": URL(fileURLWithPath: "/tmp")],
            ["n": Double.nan],
            ["n": Double.infinity],
            ["nested": [["deep": Data([1])]]],
        ]
        for object in objects {
            #expect(throws: CheckedJSONError.invalidJSONObject(topLevelType: "Dictionary<String, Any>")) {
                try CheckedJSON.data(withJSONObject: object)
            }
        }
    }

    @Test func aNonStringKeyThrows() {
        let object: [Int: String] = [1: "a"]
        #expect(throws: CheckedJSONError.self) { try CheckedJSON.data(withJSONObject: object) }
        #expect(!CheckedJSON().isValid(object))
    }

    @Test func aFragmentNeedsFragmentsAllowed() throws {
        #expect(throws: CheckedJSONError.invalidJSONObject(topLevelType: "String")) {
            try CheckedJSON.data(withJSONObject: "text")
        }
        #expect(throws: CheckedJSONError.self) { try CheckedJSON.data(withJSONObject: 3) }
        let fragment = try CheckedJSON.data(withJSONObject: "te\"xt", options: [.fragmentsAllowed])
        #expect(String(decoding: fragment, as: UTF8.self) == #""te\"xt""#)
        #expect(CheckedJSON(options: [.fragmentsAllowed]).isValid(NSNull()))
        #expect(throws: CheckedJSONError.self) {
            try CheckedJSON.data(withJSONObject: Double.nan, options: [.fragmentsAllowed])
        }
    }

    @Test func theInstanceWritesWithItsOptions() throws {
        let writer = CheckedJSON(options: [.sortedKeys])
        #expect(writer.isValid(["z": 1, "a": 2]))
        #expect(String(decoding: try writer.data(["z": 1, "a": 2]), as: UTF8.self) == #"{"a":2,"z":1}"#)
    }
}
