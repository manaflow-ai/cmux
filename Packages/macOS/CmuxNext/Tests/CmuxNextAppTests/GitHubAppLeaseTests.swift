@testable import CmuxNextApp
import Foundation
import Testing

/// Review of the App token at 535d77a: the lease named the Stack team (a UUID), which the cmux
/// API refuses as a team id, and a signed-out first launch never cleared a lease the daemon kept.
@Suite struct GitHubAppLeaseTests {
    private let project = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    private let user = "0b6c2f1e-8d0a-4a51-9a4e-5f3c7d1e2a90"
    private let stackTeam = "4c1d9e7a-2b3f-4e68-8a0c-6d5e9f1b3a27"

    /// The ids the backend derives (`domains/user.ts`), computed there with sha256 for these inputs.
    @Test func aLendNamesTheTeamByItsCmuxIDNeverItsStackID() {
        let shared = GitHubAppLease.backendTeam(stackProjectID: project, userID: user, stackTeamID: stackTeam, managed: false)
        #expect(shared == "team_18b8d7083ab4a1e6dd3e")
        #expect(shared != stackTeam)
        let personal = GitHubAppLease.backendTeam(stackProjectID: project, userID: user, stackTeamID: nil, managed: false)
        #expect(personal == "team_249f328cf8ed89fd792e")
        #expect(GitHubAppLease.backendTeam(stackProjectID: project, userID: user, stackTeamID: stackTeam, managed: true) == shared)
        #expect(GitHubAppLease.backendTeam(stackProjectID: project, userID: user, stackTeamID: nil, managed: true) == nil)
        #expect(GitHubAppLease.backendTeam(stackProjectID: project, userID: nil, stackTeamID: stackTeam, managed: false) == nil)
    }

    @Test func theFirstAccountSeenCountsEvenSignedOut() {
        // `changed` is mutating, so each result is read outside `#expect` (whose expansion
        // takes its expression as immutable).
        var account = GitHubAppLease.Account()
        let first = account.changed(user: nil, team: nil)
        #expect(first, "a signed-out launch clears a kept lease")
        let same = account.changed(user: nil, team: nil)
        #expect(!same)
        let signedIn = account.changed(user: user, team: "team_249f328cf8ed89fd792e")
        #expect(signedIn)
        let again = account.changed(user: user, team: "team_249f328cf8ed89fd792e")
        #expect(!again)
        let otherTeam = account.changed(user: user, team: "team_18b8d7083ab4a1e6dd3e")
        #expect(otherTeam)
        let signedOut = account.changed(user: nil, team: nil)
        #expect(signedOut)
    }

    /// What the stand-in daemon was sent, in order.
    @MainActor final class Daemon {
        var calls: [[String: Any]] = []
        var replies: [[String: Any]] = []
        /// Told of each call: whether it was a clear.
        var onCall: ((Bool) -> Void)?
        /// A token fetch saw its task cancelled.
        var fetchCancelled = false
        func call(_ params: [String: Any]) -> [String: Any]? {
            calls.append(params)
            onCall?(params["clear"] as? Bool == true)
            return replies.isEmpty ? ["lent": params["clear"] == nil] : replies.removeFirst()
        }
        func seq(_ i: Int) -> UInt64? { (calls[i]["seq"] as? UInt64) }
    }

    /// An install token (unsigned; only its claims are read) for `user` in `team`.
    private func jwt(user: String, team: String) -> String {
        let claims = try! JSONSerialization.data(withJSONObject: ["sub": user, "team": team, "exp": 4_102_444_800])
        let part = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(part).sig"
    }

    private struct NoToken: Error {}

    /// Review of the lender at 862f252: a team switch only queued the new lend, so when its
    /// token could not be had the daemon kept the earlier team's sign-in.
    @MainActor @Test func aSwitchClearsTheEarlierSignInBeforeItFetchesTheNext() async {
        let daemon = Daemon()
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon.call($0) }, tokens: { _ in throw NoToken() })
        lease.accountChanged(user: "user_a", team: "team_1")
        await lease.settled()
        lease.stop()
        #expect(daemon.calls.count == 1)
        #expect(daemon.calls.first?["clear"] as? Bool == true)
    }

    /// Review of the lender at 862f252: the install identity follows the account on its own, so
    /// right after a switch it could still hand out the user before's token.
    @MainActor @Test func aTokenOfAnotherAccountOrTeamIsNeverLent() async {
        let daemon = Daemon()
        let other = jwt(user: "user_b", team: "team_1")
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon.call($0) }, tokens: { _ in other })
        lease.accountChanged(user: "user_a", team: "team_1")
        await lease.settled()
        lease.stop()
        #expect(daemon.calls.count == 1, "only the clear")
        #expect(!daemon.calls.contains { $0["bearer"] != nil })

        let right = jwt(user: "user_a", team: "team_1")
        let daemon2 = Daemon()
        let lease2 = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon2.call($0) }, tokens: { _ in right })
        lease2.accountChanged(user: "user_a", team: "team_1")
        await lease2.settled()
        lease2.stop()
        #expect(daemon2.calls.count == 2)
        #expect(daemon2.calls[0]["clear"] as? Bool == true)
        #expect(daemon2.calls[1]["bearer"] as? String == right)
        #expect(daemon2.calls[1]["team"] as? String == "team_1")
        #expect((daemon2.seq(1) ?? 0) > (daemon2.seq(0) ?? .max), "the lend is newer than the clear")
    }

    /// Review of the lender at 862f252: a reply refusing a clear as older than the daemon's
    /// lease counted as taken, so a lease from an app run whose clock was ahead stayed.
    @MainActor @Test func aClearTheDaemonCallsOlderGoesAgainPastItsSeq() async {
        let daemon = Daemon()
        let ahead: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        daemon.replies = [["lent": true, "stale": true, "seq": NSNumber(value: ahead)], ["lent": false]]
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon.call($0) }, tokens: { _ in throw NoToken() })
        lease.accountChanged(user: nil, team: nil)
        await lease.settled()
        lease.stop()
        #expect(daemon.calls.count == 2)
        #expect(daemon.seq(1) == ahead + 1)
        #expect(daemon.calls[1]["clear"] as? Bool == true)
    }

    /// Review of the lender at df7ca0f: the lease was cleared only once `isSignedIn` turned
    /// false, at the end of a sign-out, so a failed install revoke left the daemon minting with it.
    @MainActor @Test func aSignOutClearsTheLeaseWhenItStarts() async {
        let daemon = Daemon()
        let token = jwt(user: "user_a", team: "team_1")
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon.call($0) }, tokens: { _ in token })
        lease.accountChanged(user: "user_a", team: "team_1")
        await lease.settled()
        let lent = daemon.calls.count
        #expect(daemon.calls.last?["bearer"] as? String == token)
        lease.signOutStarted()
        await lease.settled()
        lease.stop()
        #expect(daemon.calls.count == lent + 1)
        #expect(daemon.calls.last?["clear"] as? Bool == true)
        #expect((daemon.seq(lent) ?? 0) > (daemon.seq(lent - 1) ?? .max), "newer than the lend")
    }

    /// Review of the lender at d506d1f: a sign-out's clear queued behind a renewal whose token
    /// fetch hung, so the daemon kept the sign-in (and could mint with it) while it did.
    @MainActor @Test(.timeLimit(.minutes(1))) func aSignOutsClearNeverWaitsForATokenFetch() async {
        let daemon = Daemon()
        let (calls, called) = AsyncStream.makeStream(of: Bool.self)
        daemon.onCall = { called.yield($0) }
        let (fetches, fetching) = AsyncStream.makeStream(of: Void.self)
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let token = jwt(user: "user_a", team: "team_1")
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { daemon.call($0) }, tokens: { _ in
            fetching.yield()
            var wait = gate.makeAsyncIterator()
            _ = await wait.next()
            if Task.isCancelled {
                daemon.fetchCancelled = true
                throw CancellationError()
            }
            return token
        })
        var call = calls.makeAsyncIterator()
        var fetch = fetches.makeAsyncIterator()
        lease.accountChanged(user: "user_a", team: "team_1")
        #expect(await call.next() == true, "the fence")
        _ = await fetch.next()
        lease.signOutStarted()
        #expect(await call.next() == true, "the clear goes while the fetch still hangs")
        // Review of the lender at b935c71: the superseded fetch went on (changes in a row piled
        // them up), and its failure counted against the current change's retries.
        await lease.settled()
        #expect(daemon.fetchCancelled, "the superseded fetch is cancelled")
        #expect(lease.failures == 0, "its failure is not the current change's")
        lease.stop()
        open.finish()
        #expect(!daemon.calls.contains { $0["bearer"] != nil }, "the fetch that hung lends nothing")
    }

    @MainActor final class Line: AgentDialogLine {
        let isPerson: Bool
        var calls: [[String: Any]] = []
        var closed = false
        init(isPerson: Bool) { self.isPerson = isPerson }
        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            calls.append(params)
            return ["lent": true]
        }
        func close() { closed = true }
    }

    /// Review of the lender at ac6b681: a line whose person proof was refused (an older daemon, or
    /// another at the socket path) was still sent the bearer.
    @MainActor @Test func theSignInGoesOnlyToADaemonThatTookThePersonProof() async {
        let params: [String: Any] = ["seq": UInt64(1), "bearer": "install-token", "team": "team_1"]
        let unproven = Line(isPerson: false)
        #expect(await GitHubAppLease.send(on: unproven, params) == nil)
        #expect(unproven.calls.isEmpty, "nothing, the bearer included, reaches it")
        #expect(unproven.closed)
        let proven = Line(isPerson: true)
        #expect(await GitHubAppLease.send(on: proven, params)?["lent"] as? Bool == true)
        #expect(proven.calls.first?["bearer"] as? String == "install-token")
        #expect(proven.closed)
    }

    /// Review of the lender at 4d7b091: a renewal timer of the sign-in before that fired as a
    /// sign-out came queued its lend after the sign-out's clear, which cancelled the clear, so
    /// the daemon kept the sign-in.
    @MainActor @Test func aTimerOfTheAccountBeforeNeverCancelsTheClearAfterIt() async {
        let daemon = Daemon()
        let token = jwt(user: "user_a", team: "team_1")
        // A cancelled call never reaches acpmux (the real line ends with its task).
        let lease = GitHubAppLease(origin: "https://cloud-api.cmux.dev", call: { params in
            Task.isCancelled ? nil : daemon.call(params)
        }, tokens: { _ in token })
        lease.accountChanged(user: "user_a", team: "team_1")
        await lease.settled()
        let before = lease.generation
        #expect(daemon.calls.last?["bearer"] as? String == token)
        lease.signOutStarted()
        lease.lend(before)
        await lease.settled()
        lease.stop()
        #expect(daemon.calls.last?["clear"] as? Bool == true, "the sign-out's clear reached the daemon")
        #expect(!daemon.calls.dropFirst(2).contains { $0["bearer"] != nil }, "nothing was lent after it")
    }
}
