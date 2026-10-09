import CmuxMobileHost
import CmuxMobileWire
import CmuxNextDaemon
@testable import CmuxNextMobileLink
import Foundation
import Testing

/// The daemon-backed adapters D1b wires into the phone host: C4 roots, C13
/// git reads, C14 workspace processes.
@Suite("mobile host adapters")
struct MobileAdapterTests {
    let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u_alice", platform: "ios", appVersion: "1.0")

    @Test func eachWorkspaceRootIsItsFirstTerminalsDirectory() async throws {
        let tree = try MobileTreeProjectionTests.tree()
        let roots = await DaemonFileRoots { tree }.roots(for: principal)
        #expect(roots == [MobileFileRoot(id: "ws_abc80578cfad5ea82be750435458066f", name: "fx",
                                         url: URL(fileURLWithPath: "/tmp", isDirectory: true), writable: true)])
        let unreachable = await DaemonFileRoots { throw DaemonError.notConnected }.roots(for: principal)
        #expect(unreachable.isEmpty)
    }

    @Test func gitReadsConvertParamsAndMapNotARepository() async throws {
        let reader = DaemonGitReader { operation, params in
            #expect(operation == "git.status")
            #expect(params["path"] == .string("/tmp/repo"))
            return .object(["root": .string("/tmp/repo"), "branch": .string("main")])
        }
        let result = try await reader.read("git.status", params: ["path": "/tmp/repo"])
        #expect(result["branch"] == "main")
        let refused = DaemonGitReader { _, _ in
            throw DaemonError.command(cmd: "resource", message: "not a git repository", code: "operation.failed",
                                      details: .object(["extra": .object(["code": .string("not_a_repository")])]))
        }
        await #expect(throws: MobileDaemonError(code: "git.not_a_repo", message: "not a git repository")) {
            _ = try await refused.read("git.status", params: ["path": "/tmp"])
        }
        let failed = DaemonGitReader { _, _ in throw DaemonError.notConnected }
        await #expect(throws: DaemonError.self) { _ = try await failed.read("git.diff", params: ["path": "/tmp"]) }
    }

    @Test func workspaceProcessesComeFromTheTerminalsProcessTrees() async throws {
        let tree = try MobileTreeProjectionTests.tree()
        let processes = DaemonWorkspaceProcesses(tree: { tree }, resources: { surfaces in
            #expect(Set(surfaces.map(\.rawValue)) == [2, 5, 6])
            return TerminalResourcesRequest.Response(sampledAtNanos: 1, terminals: [
                .init(surface: SurfaceID(rawValue: 2), pid: 100,
                      host: .init(pid: 99, name: "__terminal-host", cpuNanos: 0, memoryBytes: 0),
                      processes: [.init(pid: 100, name: "zsh", cpuNanos: 0, memoryBytes: 0),
                                  .init(pid: 101, ppid: 100, name: "node", cpuNanos: 0, memoryBytes: 0)]),
                .init(surface: SurfaceID(rawValue: 5), pid: 200, host: nil,
                      processes: [.init(pid: 101, name: "node", cpuNanos: 0, memoryBytes: 0)]),
            ])
        })
        let found = await processes.processes()
        #expect(found.map(\.pid) == [100, 101])
        #expect(found.allSatisfy { $0.workspace == "ws_abc80578cfad5ea82be750435458066f" })
        #expect(found.last?.name == "node")
    }
}
