import CMUXCore
import XCTest

final class JSONValueTests: XCTestCase {
    func testJSONValueDecodesNestedObjects() throws {
        let data = #"{"name":"cmux","ready":true,"count":2,"items":["a",null]}"#.data(using: .utf8)!

        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(
            value,
            .object([
                "name": .string("cmux"),
                "ready": .bool(true),
                "count": .number(2),
                "items": .array([.string("a"), .null]),
            ])
        )
    }

    func testJSONValueEncodesNull() throws {
        let data = try JSONEncoder().encode(JSONValue.null)
        let object = try JSONSerialization.jsonObject(with: data, options: .allowFragments)

        XCTAssertTrue(object is NSNull)
    }
}
