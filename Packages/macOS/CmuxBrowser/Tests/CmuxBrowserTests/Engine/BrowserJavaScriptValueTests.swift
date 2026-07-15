import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserJavaScriptValueTests {
    @Test func copiesNestedFoundationValues() throws {
        let value = try BrowserJavaScriptValue(foundationValue: [
            "enabled": true,
            "count": 3,
            "items": ["first", NSNull()],
        ])

        #expect(value == .object([
            "enabled": .bool(true),
            "count": .number(3),
            "items": .array([.string("first"), .null]),
        ]))
    }

    @Test func distinguishesUndefinedFromNull() throws {
        #expect(try BrowserJavaScriptValue(foundationValue: nil) == .undefined)
        #expect(try BrowserJavaScriptValue(foundationValue: NSNull()) == .null)
    }

    @Test func rejectsNonTransferableValues() {
        #expect(throws: BrowserEngineSessionError.self) {
            try BrowserJavaScriptValue(foundationValue: Date())
        }
    }
}
