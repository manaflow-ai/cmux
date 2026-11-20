@testable import CmuxNextCloud
import Testing

/// `CloudAuth.storedSession` (what NIGHTLY hands over its socket) never pairs one refresh's access token
/// with another refresh's refresh token.
@Suite struct CloudAuthStoredSessionTests {
    /// A store whose tokens rotate (a refresh) after a given number of refresh-token reads.
    actor RotatingStore {
        var generation = 0
        var reads = 0
        let rotateAfterReads: [Int]
        init(rotateAfterReads: [Int]) { self.rotateAfterReads = rotateAfterReads }
        func refresh() -> String? {
            reads += 1
            defer { if rotateAfterReads.contains(reads) { generation += 1 } }
            return "refresh-\(generation)"
        }
        func access() -> String? { "access-\(generation)" }
    }

    @Test func aSteadyStoreGivesItsPair() async throws {
        let store = RotatingStore(rotateAfterReads: [])
        let pair = try #require(await CloudAuth.consistentSession(refresh: { await store.refresh() }, access: { await store.access() }))
        #expect(pair.refreshToken == "refresh-0" && pair.accessToken == "access-0")
    }

    @Test func aRefreshBetweenTheReadsIsReadAgainAsOnePair() async throws {
        // The first refresh-token read is followed by a rotation, so access and the second read are generation 1.
        let store = RotatingStore(rotateAfterReads: [1])
        let pair = try #require(await CloudAuth.consistentSession(refresh: { await store.refresh() }, access: { await store.access() }))
        #expect(pair.refreshToken == "refresh-1" && pair.accessToken == "access-1")
    }

    @Test func tokensThatKeepRotatingAreNoSession() async {
        let store = RotatingStore(rotateAfterReads: Array(1 ... 10).filter { $0 % 2 == 1 })
        #expect(await CloudAuth.consistentSession(refresh: { await store.refresh() }, access: { await store.access() }) == nil)
    }

    @Test func signedOutIsNoSession() async {
        #expect(await CloudAuth.consistentSession(refresh: { nil }, access: { "a" }) == nil)
        #expect(await CloudAuth.consistentSession(refresh: { "" }, access: { "a" }) == nil)
    }
}
