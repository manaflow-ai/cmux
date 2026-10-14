import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Stats page (hq#1920) is a preview feature: a tab restored, reached through history or left
/// open after `labs.previewFeatures` turned off must not ask acpmux to scan every session log.
@MainActor
struct StatsPageProviderGateTests {
    final class Sent: @unchecked Sendable { var lines = 0 }

    static let context = PageCallContext(page: PageDescriptor.stats.id)
    static let params: JSONValue = ["days": 7, "tzOffsetMinutes": 0]

    @Test func previewOffRefusesWithoutAskingAcpmux() async throws {
        let sent = Sent()
        let provider = StatsPageProvider(allowed: { false }) { _ in
            sent.lines += 1
            return Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        }
        let error = await #expect(throws: PageError.self) {
            try await provider.call("cmux.stats.summary", params: Self.params, context: Self.context)
        }
        #expect(error?.code == "cmux.stats.unavailable")
        #expect(error?.message == StatsPageProvider.previewRefusal)
        #expect(sent.lines == 0)
    }

    @Test func previewOnRelaysTheSummary() async throws {
        let sent = Sent()
        let provider = StatsPageProvider(allowed: { true }) { _ in
            sent.lines += 1
            return Data(#"{"jsonrpc":"2.0","id":1,"result":{"turns":3}}"#.utf8)
        }
        let reply = try await provider.call("cmux.stats.summary", params: Self.params, context: Self.context)
        #expect(reply["turns"] == 3)
        #expect(sent.lines == 1)
    }
}
