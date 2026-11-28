import CmuxNextHomeModel
import Testing

/// The Swift caller of the Rust home rules (cmux-home-rules over cmux_home_call): it
/// round-trips the foundation's `ops.list` and maps the C ABI's error statuses. The op
/// cases themselves are the Rust tests.
@Suite struct HomeRulesTests {
    @Test func opsListRoundTrips() throws {
        let names: [String] = try HomeRules.call("ops.list", HomeRules.Empty())
        #expect(names.first == "ops.list")
        #expect(HomeRules.abiVersion >= 1)
    }

    @Test func rawJSONRoundTrips() throws {
        let reply = try HomeRules.callJSON("ops.list", "{}")
        #expect(reply.hasPrefix("[\"ops.list\""))
    }

    @Test func errorsThrow() {
        #expect(throws: HomeRulesError(op: "nope.nope", code: .unknownOp, detail: nil)) {
            try HomeRules.callJSON("nope.nope", "{}")
        }
        #expect(throws: HomeRulesError(op: "ops.list", code: .invalidRequest, detail: nil)) {
            try HomeRules.callJSON("ops.list", "[]")
        }
    }
}
