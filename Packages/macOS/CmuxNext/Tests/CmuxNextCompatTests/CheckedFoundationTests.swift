import CmuxNextCompat
import Foundation
import Testing

/// The checked Foundation helpers (p10-stability-166): a value `JSONSerialization` or an `NSString` /
/// `NSAttributedString` range call would raise on comes back as a typed error or nil, never as a clamped value,
/// and a good value gives what the raw call gives.
struct CheckedFoundationTests {
    @Test func validJSONIsWrittenAsJSONSerializationWritesIt() throws {
        let object: [String: Any] = ["b": 1, "a": ["x", NSNull()]]
        let data = try CheckedJSON(options: .sortedKeys).data(object)
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":["x",null],"b":1}"#)
    }

    @Test func valuesJSONSerializationRaisesOnAreATypedError() {
        let bad: [Any] = [["when": Date()], [1: "non-string key"], [Double.nan], [Double.infinity], "scalar"]
        for value in bad {
            #expect(throws: CheckedJSON.Failure.notAJSONObject) { try CheckedJSON().data(value) }
        }
    }

    @Test func aScalarIsWrittenOnlyWithFragmentsAllowed() throws {
        #expect(throws: CheckedJSON.Failure.notAJSONObject) { try CheckedJSON().data("x") }
        let data = try CheckedJSON(options: .fragmentsAllowed).data("x")
        #expect(String(decoding: data, as: UTF8.self) == #""x""#)
        #expect(throws: CheckedJSON.Failure.notAJSONObject) {
            try CheckedJSON(options: .fragmentsAllowed).data(Date())
        }
    }

    @Test func aRangeInsideTheStringPassesUnchanged() {
        let text: NSString = "héllo"
        #expect(text.checkedRange(NSRange(location: 1, length: 3)) == NSRange(location: 1, length: 3))
        #expect(text.checkedRange(NSRange(location: 5, length: 0)) == NSRange(location: 5, length: 0))
        #expect(text.checkedSubstring(NSRange(location: 1, length: 3)) == "éll")
        #expect(text.checkedCharacter(at: 4) == unichar(UInt8(ascii: "o")))
        #expect(text.checkedIndex(0) == 0)
    }

    @Test func aRangeOutsideTheStringIsNilNotClamped() {
        let text: NSString = "hello"
        let outside = [NSRange(location: 4, length: 2), NSRange(location: 6, length: 0), NSRange(location: -1, length: 1),
                       NSRange(location: 1, length: -1), NSRange(location: NSNotFound, length: 0),
                       NSRange(location: 1, length: Int.max)]
        for range in outside {
            #expect(text.checkedRange(range) == nil, "\(range)")
            #expect(text.checkedSubstring(range) == nil, "\(range)")
        }
        #expect(text.checkedIndex(5) == nil)
        #expect(text.checkedIndex(-1) == nil)
        #expect(text.checkedCharacter(at: 5) == nil)
        #expect(("" as NSString).checkedCharacter(at: 0) == nil)
    }

    @Test func substringFromAndToAcceptTheEndAndRefusePastIt() {
        let text: NSString = "héllo"
        #expect(text.checkedSubstring(from: 1) == "éllo")
        #expect(text.checkedSubstring(to: 2) == "hé")
        #expect(text.checkedSubstring(from: 5) == "")
        #expect(text.checkedSubstring(to: 5) == "héllo")
        #expect(text.checkedSubstring(from: 0) == "héllo")
        #expect(text.checkedSubstring(to: 0) == "")
        for index in [6, -1, NSNotFound, Int.max] {
            #expect(text.checkedSubstring(from: index) == nil, "\(index)")
            #expect(text.checkedSubstring(to: index) == nil, "\(index)")
        }
    }

    @Test func attributedStringRangesAreCheckedTheSameWay() {
        let text = NSAttributedString(string: "hello")
        #expect(text.checkedRange(NSRange(location: 0, length: 5)) == NSRange(location: 0, length: 5))
        #expect(text.checkedAttributedSubstring(NSRange(location: 1, length: 2))?.string == "el")
        #expect(text.checkedRange(NSRange(location: 3, length: 3)) == nil)
        #expect(text.checkedAttributedSubstring(NSRange(location: 3, length: 3)) == nil)
        #expect(text.checkedIndex(4) == 4)
        #expect(text.checkedIndex(5) == nil)
        let mutable = NSMutableAttributedString(string: "hi")
        #expect(mutable.checkedRange(NSRange(location: 0, length: 3)) == nil)
    }
}
