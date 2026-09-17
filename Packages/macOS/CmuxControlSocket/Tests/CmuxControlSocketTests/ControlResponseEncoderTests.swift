import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlResponseEncoder")
struct ControlResponseEncoderTests {
    private let encoder = ControlResponseEncoder()

    /// Decodes a single-line response back into a dictionary for
    /// order-independent comparison (JSONSerialization key order is
    /// nondeterministic, exactly as in the legacy encoder).
    private func decode(_ line: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    @Test func okResponseMatchesLegacyShape() throws {
        let line = encoder.ok(id: .int(4), result: .object(["pong": .bool(true)]))
        let decoded = try decode(line)
        #expect(decoded == ["id": 4, "ok": true, "result": ["pong": true]] as NSDictionary)
    }

    @Test func missingIdEncodesAsNull() throws {
        let line = encoder.ok(id: nil, result: .object([:]))
        let decoded = try decode(line)
        #expect(decoded == ["id": NSNull(), "ok": true, "result": [:]] as NSDictionary)
    }

    @Test func errorResponseOmitsNilData() throws {
        let line = encoder.error(id: .string("x"), code: "invalid_params", message: "Bad")
        let decoded = try decode(line)
        #expect(decoded == [
            "id": "x",
            "ok": false,
            "error": ["code": "invalid_params", "message": "Bad"],
        ] as NSDictionary)
    }

    @Test func errorResponseCarriesData() throws {
        let line = encoder.error(
            id: nil,
            code: "invalid_params",
            message: "Bad",
            data: .object(["method": .string("m")])
        )
        let decoded = try decode(line)
        #expect(decoded == [
            "id": NSNull(),
            "ok": false,
            "error": ["code": "invalid_params", "message": "Bad", "data": ["method": "m"]],
        ] as NSDictionary)
    }

    @Test func responseBridgesCallResults() throws {
        let ok = encoder.response(id: .int(1), .ok(.string("done")))
        #expect(try decode(ok) == ["id": 1, "ok": true, "result": "done"] as NSDictionary)
        let err = encoder.response(id: .int(2), .err(code: "c", message: "m", data: nil))
        #expect(try decode(err) == [
            "id": 2,
            "ok": false,
            "error": ["code": "c", "message": "m"],
        ] as NSDictionary)
    }

    @Test func responsesAreSingleLine() {
        let line = encoder.ok(id: nil, result: .object(["text": .string("a\nb\r\nc")]))
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
    }

    @Test func parseErrorResponsesMatchLegacyStrings() throws {
        let utf8 = try decode(encoder.response(for: .invalidUTF8))
        #expect(utf8 == ["ok": false, "error": ["code": "invalid_utf8", "message": "Invalid UTF-8"]] as NSDictionary)
        #expect(utf8["id"] == nil)

        let json = try decode(encoder.response(for: .invalidJSON))
        #expect(json == ["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]] as NSDictionary)
        #expect(json["id"] == nil)

        let object = try decode(encoder.response(for: .notAnObject))
        #expect(object == ["ok": false, "error": ["code": "invalid_request", "message": "Expected JSON object"]] as NSDictionary)
        #expect(object["id"] == nil)

        let missing = try decode(encoder.response(for: .missingMethod(id: .int(9))))
        #expect(missing == [
            "id": 9,
            "ok": false,
            "error": ["code": "invalid_request", "message": "Missing method"],
        ] as NSDictionary)

        // Requests that omit "id" entirely still echo "id": null, exactly as
        // the legacy dispatcher did (v2Error always emitted v2OrNull(id)).
        let missingNilId = try decode(encoder.response(for: .missingMethod(id: nil)))
        #expect(missingNilId == [
            "id": NSNull(),
            "ok": false,
            "error": ["code": "invalid_request", "message": "Missing method"],
        ] as NSDictionary)
    }

    @Test func encodeFailureResponseIsTheLegacyConstant() {
        #expect(ControlResponseEncoder.encodeFailureResponse ==
            "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}")
    }

    @Test func topLevelFragmentsCollapseToEncodeFailure() {
        // JSONSerialization (no .fragmentsAllowed) rejects non-container top
        // levels; the legacy isValidJSONObject guard did the same.
        #expect(encoder.encode(.string("x")) == ControlResponseEncoder.encodeFailureResponse)
        #expect(encoder.encode(.int(1)) == ControlResponseEncoder.encodeFailureResponse)
    }

    @Test func okOutputIsByteIdenticalToLegacyEncoderForSortedPayload() throws {
        // Byte-level parity spot check against the legacy implementation
        // (JSONSerialization over a Foundation dictionary).
        let legacyObject: [String: Any] = [
            "id": NSNull(),
            "ok": true,
            "result": ["count": 3, "name": "ws", "ratio": 0.5, "open": false],
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let legacy = String(data: legacyData, encoding: .utf8)

        let typed = JSONValue.object([
            "id": .null,
            "ok": .bool(true),
            "result": .object(["count": .int(3), "name": .string("ws"), "ratio": .double(0.5), "open": .bool(false)]),
        ])
        let typedData = try JSONSerialization.data(
            withJSONObject: typed.foundationObject,
            options: [.sortedKeys]
        )
        #expect(String(data: typedData, encoding: .utf8) == legacy)
    }
}
