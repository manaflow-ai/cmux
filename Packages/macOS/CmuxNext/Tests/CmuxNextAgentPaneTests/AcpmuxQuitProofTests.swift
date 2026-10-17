import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Quit Everything must not turn a daemon that was present at the quit census
/// into a successful no-daemon result when shutdown removes its socket first.
struct AcpmuxQuitProofTests {
    @Test func aCensusedSocketRemovedBeforeEndIsAFailure() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpmux-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("hosts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let socket = home.appendingPathComponent("acpmux.sock")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                             socketPath: socket.path, daemonArguments: [], childEnvironment: [:])
        AcpmuxQuitProof.recordCensus(home: home, socketPresent: true)
        try FileManager.default.removeItem(at: socket)

        #expect(await AcpmuxQuit.endAgents(environment) == .failed("acpmux socket disappeared during shutdown"))
    }

    @Test func anUncensusedMissingSocketRemainsNoDaemon() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpmux-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("hosts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                             socketPath: home.appendingPathComponent("acpmux.sock").path,
                                             daemonArguments: [], childEnvironment: [:])
        #expect(await AcpmuxQuit.endAgents(environment) == .noDaemon)
    }
}
