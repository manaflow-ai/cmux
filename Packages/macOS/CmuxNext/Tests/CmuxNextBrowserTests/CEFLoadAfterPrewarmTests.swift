@testable import CmuxNextBrowser
import Testing

/// A new copy's own load of the Chromium framework waits for the launch pre-warm that loads it in the helpers
/// first (CMUX-571); with no pre-warm it waits for nothing.
@MainActor
@Suite struct CEFLoadAfterPrewarmTests {
    @Test func aLoadWaitsUntilThePrewarmEnds() async {
        let (ended, end) = AsyncStream<Void>.makeStream()
        let prewarm = Task<Void, Never> { for await _ in ended {} }
        var waited: Bool?
        let load = Task { @MainActor in waited = await CEFRuntime.afterPrewarm(prewarm) }
        for _ in 0..<20 { await Task.yield() }
        #expect(waited == nil, "the load did not wait for the pre-warm")
        end.finish()
        await load.value
        #expect(waited == true)
    }

    @Test func withNoPrewarmALoadDoesNotWait() async {
        #expect(await CEFRuntime.afterPrewarm(nil) == false)
    }
}
