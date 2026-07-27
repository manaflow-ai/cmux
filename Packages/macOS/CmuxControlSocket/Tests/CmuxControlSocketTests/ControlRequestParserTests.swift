import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("ControlRequestParser")
struct ControlRequestParserTests {
    private let parser = ControlRequestParser()

    private func strictError(_ line: String) -> ControlRequestParseError? {
        switch parser.request(fromLine: line) {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: - Lenient parse (socket-worker fast path)

    @Test func lenientParsesFullEnvelope() throws {
        let request = try #require(parser.lenientRequest(
            fromLine: #"  {"id":7,"method":" system.ping ","params":{"k":"v"}} "#
        ))
        #expect(request.id == .int(7))
        #expect(request.method == "system.ping")
        #expect(request.params == ["k": .string("v")])
    }

    @Test func lenientRequiresObjectPrefixAfterTrim() {
        #expect(parser.lenientRequest(fromLine: "ping") == nil)
        #expect(parser.lenientRequest(fromLine: #"[{"method":"x"}]"#) == nil)
        #expect(parser.lenientRequest(fromLine: "") == nil)
    }

    @Test func lenientRejectsMissingOrEmptyMethod() {
        #expect(parser.lenientRequest(fromLine: #"{"id":1}"#) == nil)
        #expect(parser.lenientRequest(fromLine: #"{"method":"  "}"#) == nil)
        #expect(parser.lenientRequest(fromLine: #"{"method":5}"#) == nil)
    }

    @Test func lenientDefaultsMissingOrNonObjectParams() throws {
        let missing = try #require(parser.lenientRequest(fromLine: #"{"method":"m"}"#))
        #expect(missing.params.isEmpty)
        #expect(missing.id == nil)
        let nonObject = try #require(parser.lenientRequest(fromLine: #"{"method":"m","params":[1]}"#))
        #expect(nonObject.params.isEmpty)
    }

    // MARK: - Strict parse (main dispatcher)

    @Test func strictParsesEnvelope() throws {
        let result = parser.request(fromLine: #"{"id":"abc","method":"surface.list","params":{"n":2}}"#)
        let request = try #require(try? result.get())
        #expect(request.id == .string("abc"))
        #expect(request.method == "surface.list")
        #expect(request.params == ["n": .int(2)])
    }

    @Test func strictClassifiesInvalidJSON() {
        #expect(strictError("not json") == .invalidJSON)
        #expect(strictError(#"{"method""#) == .invalidJSON)
    }

    @Test func strictClassifiesNonObjectTopLevel() {
        #expect(strictError("[1,2]") == .notAnObject)
    }

    @Test func strictClassifiesMissingMethodAndEchoesId() {
        #expect(strictError(#"{"id":3}"#) == .missingMethod(id: .int(3)))
        #expect(strictError(#"{"method":""}"#) == .missingMethod(id: nil))
        #expect(strictError(#"{"id":null,"method":" "}"#) == .missingMethod(id: .null))
    }

    @Test func strictDoesNotTrimLine() {
        // The legacy dispatcher parsed the raw line; leading whitespace is
        // fine for JSONSerialization, so it still parses.
        let result = parser.request(fromLine: #"  {"method":"m"}"#)
        #expect((try? result.get())?.method == "m")
    }
}
