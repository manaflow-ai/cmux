import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport

/// The prompts pending in each session are read with one `_acpmux/info` per session. Those reads
/// are independent: a peer whose info handler stalls must not hold this Mac's own prompt, nor any
/// other session's. Run one after another, one stalled read held every read listed after it
/// (the same class as hq#9137's queued reads).
@MainActor
struct AcpmuxPendingReadsTests {
    /// An acpmux that lists a peer's session first, whose `_acpmux/info` does not answer until
    /// `release()`, then this Mac's own session, whose info answers at once.
    final class StalledPeerLine: AgentDialogLine {
        var isPerson = true
        var capabilities: Set<String> = [AcpmuxSessionListGate.pendingCapability]
        private var stalled: [CheckedContinuation<[String: Any]?, Never>] = []
        private(set) var released = false

        func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
            switch method {
            case "_acpmux/sessions":
                return ["sessions": [
                    ["sessionId": "acp_peer_stalled", "peer": "peer-mac", "pendingPermissions": 1],
                    ["sessionId": "acp_own", "name": "own", "pendingPermissions": 1],
                ]]
            case "_acpmux/info" where params["sessionId"] as? String == "acp_peer_stalled":
                if released { return nil }
                return await withCheckedContinuation { stalled.append($0) }
            case "_acpmux/info":
                return ["pending": [["permissionId": "perm-own", "request": ["toolCall": ["title": "Run make"]]]]]
            default:
                return nil
            }
        }

        func release() {
            released = true
            let waiters = stalled
            stalled = []
            for waiter in waiters { waiter.resume(returning: nil) }
        }

        func close() { release() }
    }

    /// This Mac's prompt comes back within the per-read bound, not after the peer's stall.
    @Test func aStalledPeerReadDoesNotHoldThisMacsPrompt() async {
        let line = StalledPeerLine()
        // The peer answers on its own only after `stall`, far past any per-read bound.
        let stall: Duration = .seconds(10)
        let releaser = Task { @MainActor in
            try? await Task.sleep(for: stall)
            line.release()
        }
        let clock = ContinuousClock()
        let start = clock.now
        let prompts = await line.pendingPrompts()
        let took = clock.now - start
        releaser.cancel()
        line.release()
        #expect(prompts.map(\.permission) == ["perm-own"])
        #expect(took < .seconds(5), "this Mac's prompt waited \(took) on a peer's stalled _acpmux/info")
    }

    /// Reads that answer when the test says so, and what each read was asked for, in order.
    @MainActor final class Reads {
        private(set) var asked: [String] = []
        private var stalled: [String: CheckedContinuation<[String: Any]?, Never>] = [:]
        let stalls: Set<String>
        init(stalls: Set<String>) { self.stalls = stalls }

        func read(_ session: String) async -> [String: Any]? {
            asked.append(session)
            guard stalls.contains(session) else {
                return ["pending": [["permissionId": "perm-\(session)", "request": [String: Any]()]]]
            }
            return await withCheckedContinuation { stalled[session] = $0 }
        }

        var isStalled: Bool { !stalled.isEmpty }

        func release() {
            let waiters = stalled
            stalled = [:]
            for (_, waiter) in waiters { waiter.resume(returning: nil) }
        }
    }

    @MainActor final class Posted {
        var all: [(session: String, whileStalled: Bool)] = []
    }

    /// The feed bridge's shape: a peer listed first whose read stalls and a ready peer after it.
    /// The second posts while the first is still stalled, not after its deadline.
    @Test func aReadyPeerPostsWhileAnEarlierPeerStalls() async {
        let reads = Reads(stalls: ["acp_peer_stalled"])
        let rows: [[String: Any]] = [
            ["sessionId": "acp_peer_stalled", "peer": "peer-a"],
            ["sessionId": "acp_peer_ready", "peer": "peer-b"],
        ]
        let posted = Posted()
        // A deadline far past the test: only independence lets the second post in time.
        await AcpmuxPendingReads(width: 4, deadline: .seconds(600)).forEach(rows, read: { await reads.read($0) }) { _, row, entries in
            let session = row["sessionId"] as? String ?? ""
            posted.all.append((session, reads.isStalled))
            if !entries.isEmpty { reads.release() }
        }
        #expect(posted.all.map(\.session) == ["acp_peer_ready", "acp_peer_stalled"])
        #expect(posted.all.first?.whileStalled == true, "the ready peer waited for the stalled one")
    }

    /// One slot: this Mac's own sessions are read before any peer's, whatever the list order.
    @Test func thisMacsSessionsAreReadFirst() async {
        let reads = Reads(stalls: [])
        let rows: [[String: Any]] = [
            ["sessionId": "peer-1", "peer": "peer-a"],
            ["sessionId": "own-1"],
            ["sessionId": "peer-2", "peer": "peer-b"],
            ["sessionId": "own-2", "peer": ""],
        ]
        let found = await AcpmuxPendingReads(width: 1, deadline: .seconds(600)).pending(of: rows) { await reads.read($0) }
        #expect(reads.asked == ["own-1", "own-2", "peer-1", "peer-2"])
        #expect(found.map { $0.row["sessionId"] as? String ?? "" } == ["own-1", "own-2", "peer-1", "peer-2"])
        #expect(found.allSatisfy { $0.pending.count == 1 })
    }

    /// One slot and a read that never answers: its own deadline frees the slot, it counts as no
    /// prompts, and the next session is still read.
    @Test func aStalledReadEndsAtItsOwnDeadline() async {
        let reads = Reads(stalls: ["peer-stalled"])
        let rows: [[String: Any]] = [
            ["sessionId": "peer-stalled", "peer": "peer-a"],
            ["sessionId": "peer-ready", "peer": "peer-b"],
        ]
        let found = await AcpmuxPendingReads(width: 1, deadline: .milliseconds(100)).pending(of: rows) { await reads.read($0) }
        reads.release()
        #expect(reads.asked == ["peer-stalled", "peer-ready"])
        #expect(found.map(\.pending.count) == [0, 1])
    }

    /// One peer session whose info read answers only when the test says so, with one prompt.
    @MainActor final class SlowPeer {
        private var waiting: [CheckedContinuation<[String: Any]?, Never>] = []
        private(set) var asked = 0
        /// Reads asked and not answered yet.
        var outstanding: Int { waiting.count }

        func read(_ session: String) async -> [String: Any]? {
            asked += 1
            return await withCheckedContinuation { waiting.append($0) }
        }

        /// Answers every waiting read with its session's one prompt.
        func answer() {
            let waiters = waiting
            waiting = []
            // One dictionary per waiter: a resumed value is sent to its waiter, never shared.
            for waiter in waiters {
                waiter.resume(returning: ["pending": [["permissionId": "perm-late", "request": ["toolCall": ["title": "Run make"]]]]])
            }
        }

        func close() {
            let waiters = waiting
            waiting = []
            for waiter in waiters { waiter.resume(returning: nil) }
        }
    }

    /// The prompts posted, and a bounded wait for the first.
    @MainActor final class Posts {
        private(set) var all: [String] = []
        private var waiter: CheckedContinuation<Void, Never>?

        func add(_ permission: String) {
            all.append(permission)
            waiter?.resume()
            waiter = nil
        }

        /// Returns once a prompt is posted, or after `limit` on the wall clock.
        func first(within limit: Duration) async {
            guard all.isEmpty else { return }
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                self.waiter?.resume()
                self.waiter = nil
            }
            await withCheckedContinuation { waiter = $0 }
            timer.cancel()
        }
    }

    /// A peer whose info answers 15 s after a feed recovery asked, 5 s past the read's 10 s
    /// deadline: the recovery has ended (its slot freed, the read counted as no prompts), and
    /// no reconnect or new notification comes. The late answer's prompt is posted when it comes.
    /// Dropped, it reached the phone only after another reconnect.
    @Test func aPromptWhosePeerAnswersLateIsPostedWhenTheAnswerComes() async throws {
        let clock = ManualClock()
        let reads = AcpmuxPendingReads(width: 4, deadline: .seconds(10), clock: clock)
        let peer = SlowPeer()
        let posts = Posts()
        let rows: [[String: Any]] = [["sessionId": "acp_peer_late", "peer": "peer-a"]]
        let recovery = Task { @MainActor in
            await reads.forEachPrompt(rows, read: { await peer.read($0) }) { _, permission, _ in posts.add(permission) }
        }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(10))
        await recovery.value
        #expect(posts.all.isEmpty, "nothing is posted before the answer")
        clock.advance(by: .seconds(5))
        peer.answer()
        await posts.first(within: .seconds(5))
        peer.close()
        #expect(posts.all == ["perm-late"], "the late answer's prompt was not posted")
    }

    /// A peer that never answers its info read, asked on every recovery (the feed bridge after
    /// each watch reply): a recovery that finds the session's read outstanding joins it rather
    /// than asking again, so 100 recoveries leave one read, not one more each.
    @Test func aSilentPeerLeavesOneOutstandingReadAfter100Recoveries() async {
        let peer = SlowPeer()
        let reads = AcpmuxPendingReads(width: 4, deadline: .milliseconds(5))
        let rows: [[String: Any]] = [["sessionId": "acp_peer_silent", "peer": "peer-a"]]
        for _ in 0..<100 {
            let found = await reads.pending(of: rows) { await peer.read($0) }
            #expect(found.map(\.pending.count) == [0])
        }
        let (asked, outstanding) = (peer.asked, peer.outstanding)
        peer.close()
        #expect(asked == 1, "\(asked) info reads of one silent session after 100 recoveries")
        #expect(outstanding <= 1, "\(outstanding) info reads of one silent session still wait")
    }
}
