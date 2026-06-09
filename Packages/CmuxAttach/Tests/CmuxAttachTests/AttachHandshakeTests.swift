import Foundation
import Testing
@testable import CmuxAttach

@Suite struct AttachHandshakeTests {
    @Test func parsesValidRequest() throws {
        let request = try AttachHandshake.parse(params: [
            "surface": "surface:3",
            "cols": 80,
            "rows": 24,
            "read_only": true,
            "v": 1,
        ])
        #expect(request.surface == "surface:3")
        #expect(request.size == SurfaceSize(cols: 80, rows: 24))
        #expect(request.readOnly)
        #expect(request.version == 1)
    }

    @Test func readOnlyDefaultsFalseAndVersionDefaultsCurrent() throws {
        let request = try AttachHandshake.parse(params: [
            "surface": "abc",
            "cols": 100,
            "rows": 30,
        ])
        #expect(!request.readOnly)
        #expect(request.version == AttachRequest.currentVersion)
    }

    @Test func missingSurfaceThrows() {
        #expect(throws: AttachRequestError.missingSurface) {
            try AttachHandshake.parse(params: ["cols": 80, "rows": 24])
        }
    }

    @Test func blankSurfaceThrows() {
        #expect(throws: AttachRequestError.missingSurface) {
            try AttachHandshake.parse(params: ["surface": "   ", "cols": 80, "rows": 24])
        }
    }

    @Test func zeroOrNegativeColumnsThrow() {
        #expect(throws: AttachRequestError.invalidColumns(0)) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 0, "rows": 24])
        }
    }

    @Test func oversizeRowsThrow() {
        #expect(throws: AttachRequestError.invalidRows(99_999)) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 80, "rows": 99_999])
        }
    }

    @Test func booleanDimensionsAreRejectedNotCoercedToOne() {
        // A Swift Bool must not coerce to 1 (true) / 0 (false).
        #expect(throws: AttachRequestError.invalidColumns(0)) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": true, "rows": 24])
        }
    }

    @Test func jsonBooleanDimensionsAreRejected() throws {
        // The real wire path: JSONSerialization decodes a JSON `true` into a
        // CFBoolean-backed NSNumber that bridges to Int 1. The handshake must
        // still reject it rather than validating a 1x1 terminal.
        let data = Data(#"{"surface":"a","cols":true,"rows":true}"#.utf8)
        let params = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(throws: AttachRequestError.invalidColumns(0)) {
            try AttachHandshake.parse(params: params)
        }
    }

    @Test func unsupportedVersionThrows() {
        #expect(throws: AttachRequestError.unsupportedVersion(2)) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 80, "rows": 24, "v": 2])
        }
    }

    @Test func nonIntegerVersionThrows() {
        // A present-but-garbage `v` is malformed input, not a missing field, so
        // it must be rejected rather than silently coerced to the current version.
        #expect(throws: AttachRequestError.invalidVersion) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 80, "rows": 24, "v": "abc"])
        }
    }

    @Test func fractionalVersionThrows() {
        #expect(throws: AttachRequestError.invalidVersion) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 80, "rows": 24, "v": 1.5])
        }
    }

    @Test func acceptsNumericStringDimensions() throws {
        let request = try AttachHandshake.parse(params: [
            "surface": "a",
            "cols": "120",
            "rows": "40",
        ])
        #expect(request.size == SurfaceSize(cols: 120, rows: 40))
    }

    @Test func rejectsFractionalDimensions() {
        // 80.5 is not an integer column count.
        #expect(throws: AttachRequestError.self) {
            try AttachHandshake.parse(params: ["surface": "a", "cols": 80.5, "rows": 24])
        }
    }

    @Test func boolCoercionAcceptsStringsAndInts() {
        #expect(AttachHandshake.boolValue("yes") == true)
        #expect(AttachHandshake.boolValue("0") == false)
        #expect(AttachHandshake.boolValue(1) == true)
        #expect(AttachHandshake.boolValue("maybe") == nil)
    }
}
