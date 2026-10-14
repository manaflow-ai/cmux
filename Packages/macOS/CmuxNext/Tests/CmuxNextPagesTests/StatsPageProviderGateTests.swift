import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Counts the request lines a provider sent; `send` runs off the main actor.
nonisolated final class SentLines: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// The Stats page (hq#1920) is a preview feature: a tab restored, reached through history or left
/// open after `labs.previewFeatures` turned off must not ask acpmux to scan every session log.
@MainActor
struct StatsPageProviderGateTests {
    static let context = PageCallContext(page: PageDescriptor.stats.id)
    static let params: JSONValue = ["days": 7, "tzOffsetMinutes": 0]

    @Test func previewOffRefusesWithoutAskingAcpmux() async throws {
        let sent = SentLines()
        let provider = StatsPageProvider(allowed: { false }) { _ in
            sent.add()
            return Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.stats.summary", params: Self.params, context: Self.context)
        }
        #expect(error?.code == "cmux.stats.unavailable")
        #expect(error?.message == StatsPageProvider.previewRefusal)
        #expect(sent.value == 0)
    }

    @Test func previewOnRelaysTheSummary() async throws {
        let sent = SentLines()
        let provider = StatsPageProvider(allowed: { true }) { _ in
            sent.add()
            return Data(#"{"jsonrpc":"2.0","id":1,"result":{"turns":3}}"#.utf8)
        }
        let reply = try await provider.call("cmux.stats.summary", params: Self.params, context: Self.context)
        #expect(reply["turns"] == 3)
        #expect(sent.value == 1)
    }
}
