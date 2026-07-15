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

    @Test func exhaustedDescendantBypassDoesNotChangeClaimAccounting() async {
        let limiter = SocketClientPreauthorizationLimiter(maximumConcurrentClaims: 1)
        var authorization = SocketClientAuthorization()
        var ancestryEvaluationCount = 0

        #expect(await limiter.claim())
        #expect(!(await limiter.claim()))
        let admitted = authorization.cacheAncestryAuthorization(
            peerProcessID: 123,
            isDescendant: { pid in
                ancestryEvaluationCount += 1
                return pid == 123
            }
        )
        #expect(admitted)
        #expect(ancestryEvaluationCount == 1)

        await limiter.release()
        #expect(await limiter.claim())
        await limiter.release()
        await limiter.release()
        #expect(await limiter.claim())
        await limiter.release()
        #expect(await limiter.claim())
        await limiter.release()
    }

    @Test func exhaustedNonDescendantDoesNotConsumeOrReleaseAClaim() async {
        let limiter = SocketClientPreauthorizationLimiter(maximumConcurrentClaims: 1)
        var authorization = SocketClientAuthorization()

        #expect(await limiter.claim())
        #expect(!(await limiter.claim()))
        let admitted = authorization.cacheAncestryAuthorization(
            peerProcessID: 123,
            isDescendant: { _ in false }
        )
        #expect(!admitted)

        #expect(!(await limiter.claim()))
        await limiter.release()
        #expect(await limiter.claim())
        await limiter.release()
    }
}
