import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL session registry")
struct BrowserReplSessionRegistryTests {
    private let first = UUID()
    private let second = UUID()

    private func makeSession(_ name: String) -> BrowserReplSession {
        BrowserReplSession(
            id: name,
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [], agentScripts: []),
            driver: RecordingReplDriver()
        )
    }

    @Test("The same session name in another workspace is another session")
    func sessionsAreBoundToTheirWorkspace() throws {
        let registry = BrowserReplSessionRegistry()
        let here = try registry.session(for: .init(workspaceID: first, name: "work")) { _ in makeSession("work") }
        let there = try registry.session(for: .init(workspaceID: second, name: "work")) { _ in makeSession("work") }
        let again = try registry.session(for: .init(workspaceID: first, name: "work")) { _ in makeSession("work") }
        defer {
            here.close()
            there.close()
        }

        #expect(here !== there)
        #expect(here === again)
        #expect(registry.list(workspaceID: first).map(\.workspaceID) == [first])
        #expect(Set(registry.list(workspaceID: nil).map(\.workspaceID)) == [first, second])

        // Resetting in one workspace leaves the other's session alone.
        #expect(registry.reset(.init(workspaceID: second, name: "work")))
        #expect(there.isClosed && !here.isClosed)
        #expect(!registry.reset(.init(workspaceID: second, name: "work")))
    }

    /// Owner decision 2026-10-06: `--session NAME` from a caller outside
    /// cmux is one session per name, bound to the workspace focused when it
    /// was made, whatever is focused later, and never the session of that
    /// name a workspace's own callers share.
    @Test("A name from outside cmux is one stable session, apart from the workspaces' own sessions")
    func outsideNameIsOneStableSession() throws {
        let registry = BrowserReplSessionRegistry()
        let inside = try registry.session(for: .init(workspaceID: first, name: "work")) { _ in makeSession("work") }
        let outside = try registry.outsideSession(named: "work", focusedWorkspace: first) { _, _ in makeSession("work") }
        let later = try registry.outsideSession(named: "work", focusedWorkspace: second) { _, _ in makeSession("work") }
        defer {
            inside.close()
            outside.session.close()
        }

        #expect(outside.session !== inside)
        #expect(later.session === outside.session)
        #expect(later.key.workspaceID == first)
        #expect(registry.list(workspaceID: first).count == 1)
        #expect(registry.list(workspaceID: first).first?.outsideCmux == false)
        #expect(registry.listOutside().map(\.workspaceID) == [first])
        #expect(registry.list(workspaceID: nil).filter(\.outsideCmux).count == 1)

        // The workspace's own reset leaves the outside session alone, and
        // the other way round.
        #expect(registry.reset(outsideNamed: "work"))
        #expect(outside.session.isClosed && !inside.isClosed)
        #expect(!registry.reset(outsideNamed: "work"))
        #expect(throws: BrowserReplSessionRegistry.Refusal.noWorkspace) {
            try registry.outsideSession(named: "fresh", focusedWorkspace: nil) { _, _ in makeSession("fresh") }
        }
    }

    /// A session made without `--session` (one-shot, interactive, MCP)
    /// carries its client's private owner token: no other client lists it,
    /// attaches to it or resets it, even knowing its name. A named session
    /// stays shared by name.
    @Test("A session with an owner token is unlisted and unreachable without that token")
    func ownedSessionIsPrivateToItsClient() throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: first, name: "mcp-123-abc")
        let owned = try registry.session(for: key, owner: "token-a") { _ in makeSession(key.name) }
        let shared = try registry.session(for: .init(workspaceID: first, name: "shared")) { _ in makeSession("shared") }
        defer {
            owned.close()
            shared.close()
        }

        for intruder in [nil, "token-b"] as [String?] {
            #expect(throws: BrowserReplSessionRegistry.Refusal.ownedByAnotherClient) {
                try registry.session(for: key, owner: intruder) { _ in makeSession(key.name) }
            }
            #expect(!registry.reset(key, owner: intruder))
            #expect(registry.reset(name: key.name, workspaceID: nil, owner: intruder) == 0)
            #expect(registry.list(workspaceID: first, owner: intruder).map(\.name) == ["shared"])
            #expect(registry.list(workspaceID: nil, owner: intruder).map(\.name) == ["shared"])
        }
        #expect(!owned.isClosed)

        #expect(try registry.session(for: key, owner: "token-a") { _ in makeSession(key.name) } === owned)
        #expect(registry.list(workspaceID: first, owner: "token-a").map(\.name) == ["mcp-123-abc", "shared"])
        #expect(try registry.session(for: .init(workspaceID: first, name: "shared")) { _ in makeSession("shared") } === shared)
        #expect(registry.reset(key, owner: "token-a"))
        #expect(owned.isClosed)
    }

    /// A private session can end by itself (its JavaScript heap passed its
    /// limit) and stay in the registry, closed, until its idle timer
    /// removes it. Its name is still its owner's then: another client that
    /// knows or guesses the name makes no session under it.
    @Test("A private session that ended by itself is made again only for its owner token")
    func endedPrivateSessionKeepsItsOwner() throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: first, name: "cli-123-abc")
        let owned = try registry.session(for: key, owner: "token-a") { _ in makeSession(key.name) }
        owned.close()
        #expect(owned.isClosed)

        var made = 0
        for intruder in [nil, "token-b"] as [String?] {
            #expect(throws: BrowserReplSessionRegistry.Refusal.ownedByAnotherClient) {
                try registry.session(for: key, owner: intruder) { _ in
                    made += 1
                    return makeSession(key.name)
                }
            }
            #expect(!registry.reset(key, owner: intruder))
            #expect(registry.list(workspaceID: first, owner: intruder).isEmpty)
        }
        #expect(made == 0)

        let again = try registry.session(for: key, owner: "token-a") { _ in makeSession(key.name) }
        defer { again.close() }
        #expect(again !== owned && !again.isClosed)
        #expect(registry.list(workspaceID: first, owner: "token-a").map(\.name) == [key.name])
    }

    /// A named session is shared by name: an owner token on it would hide
    /// it from every other client's list, attach and reset while it holds
    /// the name (and a session slot). A token is taken only with a name a
    /// client makes for itself (`cli-`, `mcp-`, `oneshot-`).
    @Test("An owner token on a shared session name is refused and the name stays free")
    func ownerTokenCannotSquatSharedName() throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: first, name: "work")
        var made = 0
        #expect(throws: BrowserReplSessionRegistry.Refusal.ownerOnSharedName) {
            try registry.session(for: key, owner: "squatter") { _ in
                made += 1
                return makeSession(key.name)
            }
        }
        #expect(made == 0)
        let shared = try registry.session(for: key) { _ in makeSession(key.name) }
        defer { shared.close() }
        #expect(registry.list(workspaceID: first).map(\.name) == ["work"])
        for name in ["cli-1-a", "mcp-1-a", "oneshot-\(UUID().uuidString)"] {
            let own = try registry.session(for: .init(workspaceID: first, name: name), owner: "token") { _ in makeSession(name) }
            own.close()
        }
    }

    @Test("Resetting a name in every workspace closes each session with that name")
    func resetEverywhere() throws {
        let registry = BrowserReplSessionRegistry()
        let sessions = try [first, second].map { workspace in
            try registry.session(for: .init(workspaceID: workspace, name: "shared")) { _ in makeSession("shared") }
        }
        let other = try registry.session(for: .init(workspaceID: first, name: "other")) { _ in makeSession("other") }
        defer { other.close() }

        #expect(registry.reset(name: "shared", workspaceID: nil) == 2)
        #expect(sessions.allSatisfy { $0.isClosed })
        #expect(!other.isClosed)
    }

    @Test("Live sessions are capped; one more is refused and no session is evicted")
    func sessionQuota() throws {
        let registry = BrowserReplSessionRegistry(maximumSessions: 2)
        let a = try registry.session(for: .init(workspaceID: first, name: "a")) { _ in makeSession("a") }
        let b = try registry.session(for: .init(workspaceID: first, name: "b")) { _ in makeSession("b") }
        defer {
            a.close()
            b.close()
        }

        #expect(throws: BrowserReplSessionRegistry.Refusal.tooManySessions(limit: 2)) {
            try registry.session(for: .init(workspaceID: second, name: "c")) { _ in makeSession("c") }
        }
        #expect(!a.isClosed && !b.isClosed)
        // An existing session is still reachable at the cap.
        let again = try registry.session(for: .init(workspaceID: first, name: "a")) { _ in makeSession("a") }
        #expect(again === a)

        registry.reset(.init(workspaceID: first, name: "b"))
        let c = try registry.session(for: .init(workspaceID: second, name: "c")) { _ in makeSession("c") }
        c.close()
    }

    /// A private session (no `--session`) is invisible to other clients and
    /// only its owner resets it, so a client killed before its cleanup
    /// leaves it until it idles out. Private sessions together hold at most
    /// three quarters of the slots, so they never starve named sessions,
    /// which any client can list and reset.
    @Test("Private sessions leave a quarter of the session slots to named sessions")
    func privateSessionsCannotStarveNamedSessions() throws {
        let registry = BrowserReplSessionRegistry(maximumSessions: 4)
        var made: [BrowserReplSession] = []
        defer { made.forEach { $0.close() } }
        for (index, name) in ["cli-1-a", "mcp-2-b", "oneshot-3"].enumerated() {
            let key = BrowserReplSessionKey(workspaceID: first, name: name)
            made.append(try registry.session(for: key, owner: "owner-\(index)") { _ in makeSession(name) })
        }

        // Its own refusal: only its owner resets a private session, so the
        // app cannot tell the caller to reset one by name.
        #expect(throws: BrowserReplSessionRegistry.Refusal.tooManyPrivateSessions(limit: 3)) {
            try registry.session(for: .init(workspaceID: first, name: "cli-4-d"), owner: "owner-4") { _ in
                makeSession("cli-4-d")
            }
        }
        made.append(try registry.session(for: .init(workspaceID: first, name: "shared")) { _ in makeSession("shared") })
        #expect(made.allSatisfy { !$0.isClosed })
    }

    /// The owner token comes from the socket and is kept with the session
    /// for its life, so it is bounded like the name: one past 128 bytes
    /// makes no session.
    @Test("An owner token past 128 bytes makes no session")
    func ownerTokensAreBounded() throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: first, name: "cli-1-a")
        var made = 0
        #expect(throws: BrowserReplSessionRegistry.Refusal.self) {
            try registry.session(for: key, owner: String(repeating: "t", count: 129)) { _ in
                made += 1
                return makeSession(key.name)
            }
        }
        #expect(made == 0)
        #expect(registry.list(workspaceID: nil, owner: String(repeating: "t", count: 129)).isEmpty)
        let session = try registry.session(for: key, owner: String(repeating: "t", count: 128)) { _ in makeSession(key.name) }
        session.close()
    }

    @Test("Session names are short and of a plain character set")
    func sessionNames() throws {
        let registry = BrowserReplSessionRegistry()
        for bad in ["", String(repeating: "a", count: 65), "a b", "../x", "a/b", "é", "a\nb"] {
            #expect(throws: BrowserReplSessionRegistry.Refusal.invalidName, "\(bad)") {
                try registry.session(for: .init(workspaceID: first, name: bad)) { _ in makeSession("bad") }
            }
        }
        let good = try registry.session(for: .init(workspaceID: first, name: "Work.1_a-b")) { _ in makeSession("good") }
        good.close()
        #expect(BrowserReplSessionRegistry.isValidName(String(repeating: "a", count: 64)))
    }

    @Test("A session made again after a reset gets a new instance id, which names its workspace and name")
    func instanceIDsAreNeverReused() throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: first, name: "work")
        var ids: [String] = []
        for _ in 0..<2 {
            let session = try registry.session(for: key) { instanceID in
                ids.append(instanceID)
                return makeSession("work")
            }
            registry.reset(key)
            #expect(session.isClosed)
        }

        #expect(ids.count == 2 && ids[0] != ids[1])
        for id in ids {
            #expect(BrowserReplSessionKey(instanceID: id) == key)
        }
        #expect(BrowserReplSessionKey(instanceID: "work") == nil)
    }
    /// Owner decision 2026-10-06: a session that idles out keeps the tabs
    /// it opened that the user can see (they become the user's); a reset
    /// closes every one. The driver learns which end it was.
    @Test("An idle timeout ends the session as idle, a reset as closed, and only an idle end keeps a visible tab", .timeLimit(.minutes(1)))
    func idleEndKeepsVisibleTabs() async throws {
        let registry = BrowserReplSessionRegistry(idleTimeout: .milliseconds(20))
        let idleDriver = EndingRecorderDriver()
        let idleSession = try registry.session(for: .init(workspaceID: first, name: "idle")) { id in
            BrowserReplSession(id: id, cwd: browserReplTestWorkingDirectory, bundle: BrowserReplRuntimeBundle(replScripts: [], agentScripts: []), driver: idleDriver)
        }
        defer { idleSession.close() }
        #expect(await idleDriver.ending() == .idle)

        let resetDriver = EndingRecorderDriver()
        let resetSession = try registry.session(for: .init(workspaceID: first, name: "reset")) { id in
            BrowserReplSession(id: id, cwd: browserReplTestWorkingDirectory, bundle: BrowserReplRuntimeBundle(replScripts: [], agentScripts: []), driver: resetDriver)
        }
        defer { resetSession.close() }
        #expect(registry.reset(.init(workspaceID: first, name: "reset")))
        #expect(await resetDriver.ending() == .closed)

        #expect(!BrowserReplSessionEnd.idle.closesOpenedTab(visibleToUser: true))
        #expect(BrowserReplSessionEnd.idle.closesOpenedTab(visibleToUser: false))
        #expect(BrowserReplSessionEnd.closed.closesOpenedTab(visibleToUser: true))
        #expect(BrowserReplSessionEnd.closed.closesOpenedTab(visibleToUser: false))
    }
}

/// Records how its session ended (``BrowserReplDriver/detach(ending:)``).
private final class EndingRecorderDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: BrowserReplSessionEnd?
    private var waiters: [CheckedContinuation<BrowserReplSessionEnd, Never>] = []

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> { .success("null") }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}

    func detach() { detach(ending: .closed) }

    func detach(ending: BrowserReplSessionEnd) {
        let pending: [CheckedContinuation<BrowserReplSessionEnd, Never>] = lock.withLock {
            guard recorded == nil else { return [] }
            recorded = ending
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: ending) }
    }

    /// How the session ended, once it has.
    func ending() async -> BrowserReplSessionEnd {
        await withCheckedContinuation { continuation in
            let now: BrowserReplSessionEnd? = lock.withLock {
                if let recorded { return recorded }
                waiters.append(continuation)
                return nil
            }
            if let now { continuation.resume(returning: now) }
        }
    }
}
