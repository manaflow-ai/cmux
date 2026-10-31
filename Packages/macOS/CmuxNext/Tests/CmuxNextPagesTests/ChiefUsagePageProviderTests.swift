import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The argument lists a provider passed to its runner.
private actor RunLog {
    private(set) var runs: [[String]] = []
    func add(_ arguments: [String]) { runs.append(arguments) }
}

private nonisolated struct ToolExit: Error {}

/// `cmux.chief_usage.summary` (chief-usage-analytics-DESIGN.md): params become an allowlisted
/// `optchat-chief usage` argument list, and the tool's JSON goes back to the page as is.
@MainActor
struct ChiefUsagePageProviderTests {
    static let context = PageCallContext(page: PageDescriptor.chiefUsage.id)
    nonisolated static let summary = #"{"since":"7d","bucket":"day","totals":{"cost":1.5,"tokens":{"input":10}},"top":[{"key":"chief","cost":1.5}]}"#

    private static func provider(_ log: RunLog, answer: @escaping @Sendable () throws -> Data?) -> ChiefUsagePageProvider {
        ChiefUsagePageProvider { arguments in
            await log.add(arguments)
            return try answer()
        }
    }

    @Test func paramsBecomeTheExactArguments() async throws {
        let log = RunLog()
        let provider = Self.provider(log) { Data(Self.summary.utf8) }
        let params: JSONValue = ["since": "30d", "by": "model", "top": 8, "bucket": "week"]
        _ = try await provider.call("cmux.chief_usage.summary", params: params, context: Self.context)
        #expect(await log.runs == [["usage", "--since", "30d", "--by", "model", "--top", "8", "--bucket", "week"]])
    }

    @Test func missingParamsLeaveTheirFlagsOut() async throws {
        let log = RunLog()
        let provider = Self.provider(log) { Data(Self.summary.utf8) }
        _ = try await provider.call("cmux.chief_usage.summary", params: ["since": "all", "bucket": .null], context: Self.context)
        _ = try await provider.call("cmux.chief_usage.summary", params: [:], context: Self.context)
        #expect(await log.runs == [["usage", "--since", "all"], ["usage"]])
    }

    @Test func unknownOpRunsNothing() async throws {
        let log = RunLog()
        let provider = Self.provider(log) { Data(Self.summary.utf8) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.chief_usage.backfill", params: [:], context: Self.context)
        }
        #expect(error?.code == "cmux.protocol.unknown_op")
        #expect(await log.runs.isEmpty)
    }

    @Test(arguments: [
        ["since": "2d"] as JSONValue,
        ["since": "--json"],
        ["since": 7],
        ["by": "workspace"],
        ["by": "chief; rm -rf ~"],
        ["bucket": "year"],
        ["top": 51],
        ["top": -1],
        ["top": 2.5],
        ["top": "8"],
    ])
    func badParamsRunNothing(_ params: JSONValue) async throws {
        let log = RunLog()
        let provider = Self.provider(log) { Data(Self.summary.utf8) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.chief_usage.summary", params: params, context: Self.context)
        }
        #expect(error?.code == "cmux.protocol.invalid_params")
        #expect(await log.runs.isEmpty)
    }

    @Test func noToolIsUnavailable() async throws {
        let provider = Self.provider(RunLog()) { nil }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.chief_usage.summary", params: ["since": "7d"], context: Self.context)
        }
        #expect(error?.code == "cmux.chief_usage.unavailable")
        #expect(error?.message.isEmpty == false)
    }

    @Test func nonZeroExitFails() async throws {
        let provider = Self.provider(RunLog()) { throw ToolExit() }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.chief_usage.summary", params: ["since": "7d"], context: Self.context)
        }
        #expect(error?.code == "cmux.chief_usage.failed")
        #expect(error?.retryable == true)
    }

    @Test func badJSONFails() async throws {
        let provider = Self.provider(RunLog()) { Data("usage: no ledger\n{".utf8) }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.chief_usage.summary", params: ["since": "7d"], context: Self.context)
        }
        #expect(error?.code == "cmux.chief_usage.failed")
        #expect(error?.retryable == true)
    }

    @Test func goodJSONIsReturnedAsIs() async throws {
        let provider = Self.provider(RunLog()) { Data(Self.summary.utf8) }
        let reply = try await provider.call("cmux.chief_usage.summary", params: ["since": "7d"], context: Self.context)
        #expect(reply == (try JSONValue.parse(Data(Self.summary.utf8))))
        #expect(reply["totals"]?["cost"] == 1.5)
    }
}
