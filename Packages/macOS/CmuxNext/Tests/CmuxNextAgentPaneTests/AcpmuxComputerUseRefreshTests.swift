import Foundation
import Testing
@testable import CmuxNextAgentPane

/// acpmux learned the Computer Use endpoint only when a pane looked up its
/// daemon. When the app replaced the agent token (a helper that failed its
/// running check), panes already connected never looked again, so acpmux
/// kept the old token and every new chat's helper calls were refused until a
/// pane reconnected or the app restarted. The host now pushes the new
/// endpoint to its daemon when it changes.
struct AcpmuxComputerUseRefreshTests {
    private nonisolated final class Box: @unchecked Sendable {  // the lock guards both fields
        private let lock = NSLock()
        private var current: [String: String]
        private var sent: [[String: String]] = []
        init(_ value: [String: String]) { current = value }
        var value: [String: String] {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
        var enrolled: [[String: String]] { lock.withLock { sent } }
        func record(_ endpoint: [String: String]) { lock.withLock { sent.append(endpoint) } }
    }

    private static func environment(root: URL, signed: Bool = true, attached: Bool = false) -> AcpmuxEnvironment {
        var environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/App/bin/acpmux"),
                                            home: root.appending(path: "home"),
                                            socketPath: root.appending(path: "acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:],
                                            passesPersonKeyAtSpawn: !signed)
        environment.isAttached = attached
        return environment
    }

    private static func endpoint(_ token: String) -> [String: String] {
        ["CMUX_NEXT_CUA_SOCKET": "/private/cua.sock", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": token]
    }

    private static func host(_ environment: AcpmuxEnvironment, _ box: Box) -> AcpmuxHost {
        AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment }, computerUse: { box.value },
                   enrollComputerUse: { box.record($0.computerUse) })
    }

    @Test func aReplacedTokenReachesTheRunningDaemon() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "acpmux-cu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = Self.environment(root: root)
        // A daemon listens on the socket.
        try Data().write(to: URL(fileURLWithPath: environment.socketPath))
        let box = Box(Self.endpoint("old"))
        let host = Self.host(environment, box)

        box.value = Self.endpoint("new")
        await host.computerUseChanged()
        #expect(box.enrolled == [Self.endpoint("new")])

        // Withdrawn (the helper v2 chosen): the daemon clears it too.
        box.value = [:]
        await host.computerUseChanged()
        #expect(box.enrolled == [Self.endpoint("new"), [:]])
    }

    /// Nothing to push to: no daemon runs, the daemon is another app's, or an
    /// unsigned DEV daemon took its endpoint at spawn (it refuses enrollment).
    @Test func nothingIsSentWithoutAnOwnedSignedRunningDaemon() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "acpmux-cu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box(Self.endpoint("new"))

        await Self.host(Self.environment(root: root), box).computerUseChanged()
        try Data().write(to: URL(fileURLWithPath: Self.environment(root: root).socketPath))
        await Self.host(Self.environment(root: root, attached: true), box).computerUseChanged()
        await Self.host(Self.environment(root: root, signed: false), box).computerUseChanged()
        #expect(box.enrolled.isEmpty)
    }
}
