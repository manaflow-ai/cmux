@testable import CmuxNextBrowser
import Foundation
import Testing

/// A WebKit result keeps JavaScript's booleans apart from the numbers 0 and 1,
/// on every platform's Foundation (p15-oracle-140: no CFBoolean on Linux).
@Suite struct BrowserJSValueFoundationTests {
    @Test func booleansStayBooleans() {
        #expect(BrowserJSValue(foundation: NSNumber(value: true)) == .bool(true))
        #expect(BrowserJSValue(foundation: NSNumber(value: false)) == .bool(false))
        #expect(BrowserJSValue(foundation: NSNumber(value: 1)) == .number(1))
        #expect(BrowserJSValue(foundation: NSNumber(value: 0)) == .number(0))
        #expect(BrowserJSValue(foundation: NSNumber(value: 2.5)) == .number(2.5))
    }

    @Test func parsedJSONKeepsBooleansApartFromNumbers() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"a":[true,1,0,false]}"#.utf8))
        #expect(BrowserJSValue(foundation: object) == .object(["a": .array([.bool(true), .number(1), .number(0), .bool(false)])]))
    }
}
