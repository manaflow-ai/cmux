import CmuxControlSocket
import Testing

@Suite("Socket client preauthorization limiter")
struct SocketClientPreauthorizationLimiterTests {
    @Test func rejectsBeyondLimitUntilAClaimIsReleased() async {
        let limiter = SocketClientPreauthorizationLimiter(maximumConcurrentClaims: 2)

        let first = await limiter.claim()
        let second = await limiter.claim()
        let rejected = await limiter.claim()
        #expect(first)
        #expect(second)
        #expect(!rejected)

        await limiter.release()
        let replacement = await limiter.claim()
        #expect(replacement)
    }
}
