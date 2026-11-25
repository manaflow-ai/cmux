@testable import CmuxNextComputerUse
import CmuxNextCompat
import Foundation
import Testing

struct ComputerUseHelperScopeTests {
    @Test func onlyOneLauncherCanOwnASocketScope() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cu-scope-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "socket/cua.sock").path
        let state = root.appending(path: "state")
        var lease = await ComputerUseHelperScope.acquire(socketPath: socket, stateDirectory: state)
        try #require(lease != nil)
        let competing = await ComputerUseHelperScope.acquire(socketPath: socket, stateDirectory: state)
        #expect(competing == nil)
        lease = nil
        let replacement = await ComputerUseHelperScope.acquire(socketPath: socket, stateDirectory: state)
        #expect(replacement != nil)
    }

    @Test func replacementStopsAllOldHelpersBeforeRemovingTheSocket() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cu-replace-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "socket/cua.sock")
        let state = root.appending(path: "state")
        let lease = try #require(await ComputerUseHelperScope.acquire(socketPath: socket.path, stateDirectory: state))
        try Data("old socket".utf8).write(to: socket)
        let stopped = Mutex<[Int32]>([])
        let ready = await lease.prepareForLaunch(stateDirectory: state, candidates: { _ in [123, 456] }, stop: { pid in
            #expect(FileManager.default.fileExists(atPath: socket.path))
            stopped.withLock { $0.append(pid) }
            return true
        })
        #expect(ready)
        #expect(stopped.withLock { $0 } == [123, 456])
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test func aHelperThatWillNotStopPreventsReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cu-refuse-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "socket/cua.sock")
        let state = root.appending(path: "state")
        let lease = try #require(await ComputerUseHelperScope.acquire(socketPath: socket.path, stateDirectory: state))
        try Data("old socket".utf8).write(to: socket)
        let ready = await lease.prepareForLaunch(stateDirectory: state, candidates: { _ in [123] }, stop: { _ in false })
        #expect(!ready)
        #expect(FileManager.default.fileExists(atPath: socket.path))
    }

    @Test func cleanupMatchesOnlyServeOnThisExactSocket() {
        let socket = "/tmp/cmux-cua/next/cua.sock"
        #expect(ComputerUseHelperScope.serves(socket, arguments: ["cmux-cua", "serve", "--socket", socket]))
        #expect(!ComputerUseHelperScope.serves(socket, arguments: ["cmux-cua", "serve", "--socket", "/tmp/cmux-cua/classic/cua.sock"]))
        #expect(!ComputerUseHelperScope.serves(socket, arguments: ["cmux-cua", "manifest"]))
        #expect(!ComputerUseHelperScope.serves(socket, arguments: ["cmux-cua", "serve", "--socket"]))
    }

    /// A helper that exits between the scan and the signature check must not block the launch.
    @Test func aCandidateThatAlreadyExitedCountsAsStopped() {
        #expect(ComputerUseHelperScope.stopHelper(42, isAlive: { _ in false }, isSigned: { _ in false }, stopAndWait: { _ in false }))
        // Exits right after the alive check: the signature read fails, then it is gone.
        var alive = true
        #expect(ComputerUseHelperScope.stopHelper(42, isAlive: { _ in defer { alive = false }; return alive },
                                                  isSigned: { _ in false }, stopAndWait: { _ in false }))
        // A live unsigned process on the socket is never ours to stop.
        #expect(!ComputerUseHelperScope.stopHelper(42, isAlive: { _ in true }, isSigned: { _ in false }, stopAndWait: { _ in true }))
        #expect(ComputerUseHelperScope.stopHelper(42, isAlive: { _ in true }, isSigned: { _ in true }, stopAndWait: { _ in true }))
    }
}
