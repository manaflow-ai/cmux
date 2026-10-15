@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Saved environments on the New Tab page (cx-ncc.104): `environment.list|save|remove` reach the
/// App's store only from a New Tab page, the store keeps what the contract allows and refuses the
/// rest, and the file it writes is the owner's alone.
@MainActor
struct SavedEnvironmentsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-environments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A New Tab page on `store`, as AgentPageChats seeds every page.
    private static func page(_ store: SavedEnvironments, sessionId: String? = nil) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost(), sessionId: sessionId, newTab: AgentPaneNewTab(kind: .agent))
        model.startFolders.environments = store
        return model
    }

    private static func call(_ model: AgentPaneModel, _ method: String, _ params: [String: Any] = [:]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func ssh(_ name: String = " Build box ") -> [String: Any] {
        ["name": name, "kind": "ssh", "host": "devbox",
         "folders": [["path": "/home/me/code/app", "branch": "main", "worktree": true]],
         "env": [["key": "RUST_LOG", "value": "debug"]]]
    }

    @Test func aSaveGetsAnIdAndTimeAndIsListedNewestFirst() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedEnvironments(url: directory.appending(path: "environments.json"), now: { Date(timeIntervalSince1970: 1) })
        let page = Self.page(store)
        #expect(AgentPageOps.method(for: "cmux.agent.environment.save") == "environment.save")

        let first = await Self.call(page, "environment.save", ["environment": Self.ssh()])
        let saved = try #require((first["value"] as? [String: Any])?["environment"] as? [String: Any])
        let id = try #require(saved["id"] as? String)
        #expect(UUID(uuidString: id) != nil)
        #expect(saved["name"] as? String == "Build box")
        #expect((saved["updatedAt"] as? NSNumber)?.int64Value == 1_000)
        // A clock that stands still still orders the saves (each after the last).

        _ = await Self.call(page, "environment.save", ["environment": ["name": "Laptop", "kind": "local", "folders": [], "env": []]])
        let list = await Self.call(page, "environment.list")
        let names = ((list["value"] as? [String: Any])?["environments"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["Laptop", "Build box"])

        // A save with the same id replaces it and moves it first.
        var edited = Self.ssh("Build box 2")
        edited["id"] = id
        _ = await Self.call(page, "environment.save", ["environment": edited])
        let after = await SavedEnvironments(url: directory.appending(path: "environments.json")).list()
        #expect(after.map(\.name) == ["Build box 2", "Laptop"])
        #expect(after.first?.id == id)
        #expect(after.first?.folders == [AgentPaneEnvironment.Folder(path: "/home/me/code/app", branch: "main", worktree: true)])
    }

    @Test func anEnvironmentThatBreaksTheContractIsRefused() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "environments.json")
        let page = Self.page(SavedEnvironments(url: url))
        var badKey = Self.ssh()
        badKey["env"] = [["key": "1BAD", "value": "x"]]
        var tooManyFolders = Self.ssh()
        tooManyFolders["folders"] = (0...AgentPaneEnvironment.maximumFolders).map { ["path": "/tmp/\($0)"] }
        var unknownField = Self.ssh()
        unknownField["command"] = "rm -rf /"
        var noHost = Self.ssh()
        noHost["host"] = nil
        let refused: [[String: Any]] = [
            badKey, tooManyFolders, Self.ssh("   "), Self.ssh(String(repeating: "a", count: 81)), unknownField, noHost,
            ["name": "X", "kind": "docker", "folders": [], "env": []],
        ]
        for environment in refused {
            let reply = await Self.call(page, "environment.save", ["environment": environment])
            #expect(reply["ok"] as? Bool == false)
        }
        // A param key outside the method's own is refused too.
        #expect(await Self.call(page, "environment.save", ["environment": Self.ssh(), "path": "/"])["ok"] as? Bool == false)
        #expect(await Self.call(page, "environment.remove", ["id": "not-a-uuid"])["ok"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removeDeletesIt() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "environments.json")
        let page = Self.page(SavedEnvironments(url: url))
        let reply = await Self.call(page, "environment.save", ["environment": Self.ssh()])
        let id = try #require(((reply["value"] as? [String: Any])?["environment"] as? [String: Any])?["id"] as? String)

        #expect(await Self.call(page, "environment.remove", ["id": id])["ok"] as? Bool == true)
        let list = await Self.call(page, "environment.list")
        #expect(((list["value"] as? [String: Any])?["environments"] as? [Any])?.isEmpty == true)
        #expect(await SavedEnvironments(url: url).list().isEmpty)
    }

    @Test func aChatPageCannotReadOrEditThem() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "environments.json")
        let store = SavedEnvironments(url: url)
        _ = try await store.save(AgentPaneEnvironment(name: "Kept", kind: .local))
        // A chat with a session, and a chat page that never was a New Tab page.
        let chat = Self.page(store, sessionId: "session-1")
        let plain = AgentPaneModel(host: NoHost())
        plain.startFolders.environments = store
        for model in [chat, plain] {
            for (method, params) in [("environment.list", [:]), ("environment.save", ["environment": Self.ssh()]),
                                     ("environment.remove", ["id": UUID().uuidString])] as [(String, [String: Any])] {
                let reply = await Self.call(model, method, params)
                #expect(reply["ok"] as? Bool == false)
                #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
            }
        }
        #expect(await store.list().map(\.name) == ["Kept"])
    }

    @Test func theFileIsTheOwnersAlone() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/environments.json")
        // A file left readable by others (made by hand) is replaced by an owner-only one.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        let page = Self.page(SavedEnvironments(url: url))
        #expect(await Self.call(page, "environment.save", ["environment": Self.ssh()])["ok"] as? Bool == true)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["environments.json"])
    }
}
