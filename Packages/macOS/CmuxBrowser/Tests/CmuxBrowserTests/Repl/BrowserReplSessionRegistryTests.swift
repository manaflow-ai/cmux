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
            cwd: FileManager.default.temporaryDirectory.path,
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
