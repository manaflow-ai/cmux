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
}
