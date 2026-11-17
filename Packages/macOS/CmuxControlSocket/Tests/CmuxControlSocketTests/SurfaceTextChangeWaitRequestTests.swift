import Testing
@testable import CmuxControlSocket

/// `surface.wait_text_change` params: what the wait reads, how long it may
/// wait, and when a revision answers it.
@Suite("surface.wait_text_change params")
struct SurfaceTextChangeWaitRequestTests {
    private func parse(_ params: [String: JSONValue]) -> Result<SurfaceTextChangeWaitRequest, SurfaceTextChangeWaitRequest.ParseError> {
        SurfaceTextChangeWaitRequest.parse(params)
    }

    @Test func defaultsAnswerAtOnceWithTheDefaultTimeout() throws {
        let request = try parse(["surface_id": .string("S")]).get()
        #expect(request.afterRevision == nil)
        #expect(request.timeout == .milliseconds(SurfaceTextChangeWaitRequest.defaultTimeoutMilliseconds))
        #expect(request.isAnswered(byRevision: "anything"))
    }

    @Test func readParamsDropOnlyTheWaitKeys() throws {
        let request = try parse([
            "workspace_id": .string("W"),
            "surface_id": .string("S"),
            "lines": .int(40),
            "after_revision": .string("abc"),
            "timeout_ms": .int(1_500),
        ]).get()
        #expect(request.readParams == [
            "workspace_id": .string("W"),
            "surface_id": .string("S"),
            "lines": .int(40),
        ])
        #expect(request.afterRevision == "abc")
        #expect(request.timeout == .milliseconds(1_500))
    }

    @Test func acceptsTimeoutBoundsAndWholeDoubles() throws {
        #expect(try parse(["timeout_ms": .int(0)]).get().timeout == .zero)
        #expect(try parse(["timeout_ms": .int(600_000)]).get().timeout == .milliseconds(600_000))
        #expect(try parse(["timeout_ms": .double(2_000)]).get().timeout == .milliseconds(2_000))
        #expect(try parse(["timeout_ms": .null, "after_revision": .null]).get().afterRevision == nil)
    }

    @Test("refuses timeouts outside 0...600000 ms or not whole numbers", arguments: [
        JSONValue.int(-1), .int(600_001), .double(1.5), .string("100"), .bool(true),
    ])
    func refusesBadTimeouts(value: JSONValue) {
        guard case .failure(let error) = parse(["timeout_ms": value]) else {
            Issue.record("timeout_ms \(value) was accepted")
            return
        }
        #expect(error.message.contains("timeout_ms"))
    }

    @Test("refuses a revision that is not a non-empty string", arguments: [
        JSONValue.string(""), .int(3), .array([]),
    ])
    func refusesBadRevisions(value: JSONValue) {
        guard case .failure(let error) = parse(["after_revision": value]) else {
            Issue.record("after_revision \(value) was accepted")
            return
        }
        #expect(error.message.contains("after_revision"))
    }

    @Test func revisionsFollowTheTextAndAnswerOnlyAChange() throws {
        let seen = SurfaceTextChangeWaitRequest.revision(of: "• Booting MCP server")
        #expect(seen == SurfaceTextChangeWaitRequest.revision(of: "• Booting MCP server"))
        #expect(seen != SurfaceTextChangeWaitRequest.revision(of: "• Working (1s • esc to interrupt)"))
        #expect(seen.count == 32)
        let request = try parse(["after_revision": .string(seen)]).get()
        #expect(!request.isAnswered(byRevision: seen))
        #expect(request.isAnswered(byRevision: SurfaceTextChangeWaitRequest.revision(of: "")))
    }
}
