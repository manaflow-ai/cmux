import CmuxControlSocket
import Testing

@Suite("Socket client preauthorization limiter")
struct SocketClientPreauthorizationLimiterTests {
    @Test func rejectsBeyondLimitUntilAClaimIsReleased() {
        let limiter = SocketClientPreauthorizationLimiter(maximumConcurrentClaims: 2)

        let first = limiter.claim()
        let second = limiter.claim()
        let rejected = limiter.claim()
        #expect(first)
        #expect(second)
        #expect(!rejected)

        limiter.release()
        let replacement = limiter.claim()
        #expect(replacement)
    }
}
