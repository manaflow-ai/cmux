@testable import CmuxNextSettings
import Foundation
import Testing

/// The checked-in exports (`schemas/settings`, `docs/mdm`) must be byte
/// identical on every toolchain. Foundation's JSON writers print doubles
/// differently across Xcode releases (`0.1` on one, `0.10000000000000001` on
/// another), so the exports format numbers themselves. These pins hold the
/// shortest round-trip form.
@Suite struct DeterministicJSONTests {
    @Test func doublesUseTheShortestRoundTripForm() throws {
        #expect(try DeterministicJSON.number(0.1) == "0.1")
        #expect(try DeterministicJSON.number(0.2) == "0.2")
        #expect(try DeterministicJSON.number(0.05) == "0.05")
        #expect(try DeterministicJSON.number(0.1 + 0.2) == "0.30000000000000004")
        #expect(try DeterministicJSON.number(1.0 / 3) == "0.3333333333333333")
        #expect(try DeterministicJSON.number(1e-7) == "1e-7")
        #expect(try DeterministicJSON.number(-2.5e-12) == "-2.5e-12")
        #expect(try DeterministicJSON.number(1e300) == "1e300")
        #expect(try DeterministicJSON.number(1.0) == "1")
        #expect(try DeterministicJSON.number(-0.0) == "0")
        #expect(try DeterministicJSON.number(86400) == "86400")
        for value in [0.1, 0.2, 1.0 / 3, 1e-7, 0.1 + 0.2, 1e300, 123.456] {
            #expect(try Double(DeterministicJSON.number(value)) == value, "\(value) does not round-trip")
        }
    }

    @Test func nonFiniteNumbersAreRefused() {
        #expect(throws: DeterministicJSON.Failure.self) { try DeterministicJSON.number(.nan) }
        #expect(throws: DeterministicJSON.Failure.self) { try DeterministicJSON.number(.infinity) }
    }

    @Test func prettyOutputIsPinned() throws {
        let object: [String: Any] = [
            "step": 0.1, "min": 1e-7, "third": 1.0 / 3, "count": 2, "on": true, "off": false,
            "none": NSNull(), "empty": [Any](), "nested": ["b": 0.2, "a": "x/\"y\"\n"],
            "list": [0.1, 1, "z"],
        ]
        let text = try DeterministicJSON.string(object, pretty: true)
        #expect(text == """
        {
          "count" : 2,
          "empty" : [

          ],
          "list" : [
            0.1,
            1,
            "z"
          ],
          "min" : 1e-7,
          "nested" : {
            "a" : "x/\\"y\\"\\n",
            "b" : 0.2
          },
          "none" : null,
          "off" : false,
          "on" : true,
          "step" : 0.1,
          "third" : 0.3333333333333333
        }
        """)
    }

    @Test func compactOutputIsPinned() throws {
        let object: [String: Any] = ["b": [0.1, 0.2], "a": ["k": 1.0 / 3], "c": "\u{1}"]
        #expect(try DeterministicJSON.string(object, pretty: false) == #"{"a":{"k":0.3333333333333333},"b":[0.1,0.2],"c":"\u0001"}"#)
    }

    /// The output is valid JSON that Foundation reads back to the same values.
    @Test func outputParsesBack() throws {
        let object: [String: Any] = ["v": [0.1, 1e-7, 1.0 / 3, 42, true]]
        let data = Data(try DeterministicJSON.string(object, pretty: true).utf8)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [Any]])
        let values = try #require(parsed["v"])
        #expect((values[0] as? Double) == 0.1)
        #expect((values[1] as? Double) == 1e-7)
        #expect((values[2] as? Double) == 1.0 / 3)
        #expect((values[3] as? Int) == 42)
    }
}
