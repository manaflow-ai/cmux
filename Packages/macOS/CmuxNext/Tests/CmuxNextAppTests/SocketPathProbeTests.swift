import CmuxNextAgentActivity
@testable import CmuxNextCompat
import Foundation
import Testing

/// The feeds that wait for a daemon's socket (Chats, agent turn states, agent activity) read the
/// socket's path through ``SocketPathProbe``, off the main actor: the socket file, or the folder to
/// watch for it, opened for events.
@Suite(.timeLimit(.minutes(1)))
struct SocketPathProbeTests {
    /// A fresh folder of its own under the temporary folder.
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cn-probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFileAtTheSocketPathIsPresent() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "d.sock").path
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let found = await SocketPathProbe.read(socket: socket, folder: .nearestExisting, watching: nil)
        #expect(found == .present)
    }

    /// A socket whose folders are not made yet is waited for in the deepest folder that exists.
    @Test func aMissingSocketIsWaitedForInItsNearestExistingFolder() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "home/daemon/d.sock").path
        let found = await SocketPathProbe.read(socket: socket, folder: .nearestExisting, watching: nil)
        defer { found.close() }
        guard case .absent(let watched, let descriptor) = found else {
            Issue.record("a missing socket read as \(found)")
            return
        }
        #expect(watched == folder.path)
        #expect(descriptor != nil, "the folder is opened for events")
    }

    /// The parent-only wait (agent activity) names the socket's own folder and opens nothing
    /// when that folder is missing: the caller then retries with its backoff.
    @Test func aMissingParentFolderOpensNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = folder.appending(path: "cua")
        let found = await SocketPathProbe.read(socket: parent.appending(path: "cua.sock").path, folder: .parent, watching: nil)
        #expect(found == .absent(folder: parent.path, descriptor: nil))
    }

    /// A folder event while the folder is watched reads again without opening the folder twice.
    @Test func theWatchedFolderIsNotOpenedAgain() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = await SocketPathProbe.read(socket: folder.appending(path: "d.sock").path, folder: .nearestExisting,
                                               watching: folder.path)
        #expect(found == .absent(folder: folder.path, descriptor: nil))
    }

    #if DEBUG
    /// A main-actor feed's read never stats on the main thread: in trap mode a checked file call
    /// on the main thread stops the process (BlockingCheckTests.aCheckedFileManagerCallOnTheMainThreadTraps).
    @Test func aMainActorCallerNeverStatsOnTheMainThread() async {
        await #expect(processExitsWith: .success) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await probeFromTheMainActor()
            }
        }
    }
    #endif

    /// With no socket the activity pane shows "not started" (read off the main actor, then pushed
    /// on it).
    @MainActor @Test func aMissingActivitySocketShowsNotStarted() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (updates, continuation) = AsyncStream<AgentActivityUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let source = AgentActivitySocketSource(configuration: .init(socketPath: folder.appending(path: "cua.sock").path,
                                                                    machineName: "Fixture"))
        source.start { continuation.yield($0) }
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        guard case .connection(_, let state)? = first else {
            Issue.record("the first update was \(String(describing: first))")
            return
        }
        #expect(state == .notStarted)
        withExtendedLifetime(source) {}
    }
}

/// One read from main-actor code, as the feeds make it.
@MainActor private func probeFromTheMainActor() async {
    let found = await SocketPathProbe.read(socket: "/cn-probe-missing/home/d.sock", folder: .nearestExisting, watching: nil)
    found.close()
}
