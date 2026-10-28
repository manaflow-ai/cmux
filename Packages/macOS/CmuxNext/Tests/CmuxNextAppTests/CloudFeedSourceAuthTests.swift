@testable import CmuxNextFeed
import CmuxNextWakeups
import Foundation
import Testing

/// A 401 on the feed wire upgrade is final for that token: the reconnect loop opens no
/// socket with it again and waits for a different token (cx-dgsp review follow-up).
@MainActor
@Suite struct CloudFeedSourceAuthTests {
    /// Hands out `script` in order, then repeats its last token.
    private actor Tokens {
        private var script: [String]
        private(set) var asked = 0
        init(_ script: [String]) { self.script = script }
        func next() -> String {
            asked += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }

    @MainActor private final class Connections {
        var list: [FeedConnection] = []
    }

    @Test func a401HoldsTheRefusedTokenUntilTheProviderHasAnother() async throws {
        let tokens = Tokens(["a", "a", "a", "b"])
        let (opened, opener) = AsyncStream.makeStream(of: String.self)
        let source = CloudFeedSource(
            apiBaseURL: URL(string: "https://api.test")!,
            device: "Mac", mainWork: linklessMainWork(),
            token: { await tokens.next() },
            reconnect: Backoff(initial: .milliseconds(1), maximum: .milliseconds(1), jitter: 0)
        ) { bearer, _, _ in
            opener.yield(bearer)
            if bearer == "a" { throw CloudFeedSource.Unauthorized() }
            // The new token's socket stays open until the test stops the source.
            try await Task.sleep(for: .seconds(60))
        }
        let connections = Connections()
        source.start { event in
            if case let .connection(state) = event { connections.list.append(state) }
        }
        var bearers: [String] = []
        for await bearer in opened {
            bearers.append(bearer)
            if bearer == "b" { break }
        }
        source.stop()
        // One socket for the refused token, none while the provider repeats it, then one for the new token.
        #expect(bearers == ["a", "b"])
        #expect(await tokens.asked == 4)
        #expect(connections.list.contains(.disconnected(CloudFeedSource.unauthorizedReason)))
    }
}
