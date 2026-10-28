import CmuxNextCompat
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// A Chief's avatar files are read and written on the files lane of the runner the app gives
/// ``HomeChiefAvatars`` (plans/cmux-next/chrome-parity/p02-threads.md, task 041), never in a detached task on
/// the cooperative pool: reads for the screen at `.userVisible`, a picture the person just chose at
/// `.userBlocking`.
@Suite struct HomeChiefAvatarsLaneTests {
    /// Real lanes that record the lane and priority of each item.
    nonisolated final class RecordingRunner: MayBlockRunner {
        enum Lane: Equatable { case files, system }
        let lanes = BackgroundWork(label: "test.chief-avatar-lanes")
        private let items = Mutex<[(Lane, MayBlockPriority)]>([])

        var recorded: [(Lane, MayBlockPriority)] { items.withLock { $0 } }

        func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                   _ body: @escaping @Sendable () throws -> T) async throws -> T {
            items.withLock { $0.append((.files, priority)) }
            return try await lanes.runFiles(priority, shutdown: shutdown, site: site, body)
        }

        func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                    _ body: @escaping @Sendable () throws -> T) async throws -> T {
            items.withLock { $0.append((.system, priority)) }
            return try await lanes.runSystem(priority, shutdown: shutdown, site: site, body)
        }

        func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                            _ body: @escaping @Sendable () throws -> T) async throws -> T {
            items.withLock { $0.append((.system, priority)) }
            return try await lanes.runHostResolution(priority, shutdown: shutdown, site: site, body)
        }

        func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                       _ body: @escaping @Sendable () -> Void) {
            items.withLock { $0.append((.files, priority)) }
            lanes.postFiles(priority, shutdown: shutdown, site: site, body)
        }
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-avatar-lanes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aTileReadRunsOnTheFilesLaneAtUserVisible() async throws {
        let home = try Self.folder()
        HomeChiefFiles(muxHome: home).writeAvatar("MX")
        let runner = RecordingRunner(), avatars = HomeChiefAvatars(muxHome: home, cache: try Self.folder(), files: runner)
        let shown = await avatars.read(chiefs: ["agent_mux"])
        #expect(shown == ["agent_mux": .text("MX")])
        #expect(!runner.recorded.isEmpty)
        #expect(runner.recorded.allSatisfy { $0.0 == .files && $0.1 == .userVisible })
    }

    @Test func theHeaderFallbackReadRunsOnTheFilesLaneAtUserVisible() async throws {
        let fallback = try Self.folder().appendingPathComponent("pet.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fallback)
        let runner = RecordingRunner(), files = HomeChiefFiles(muxHome: try Self.folder())
        let shown = await HomeChiefAvatars.headerAvatar(files: files, fallback: fallback, on: runner)
        #expect(shown.picture == (try Data(contentsOf: fallback)))
        #expect(runner.recorded.count == 2)  // the Chief's own files, then the fallback
        #expect(runner.recorded.allSatisfy { $0.0 == .files && $0.1 == .userVisible })
    }

    @Test func clearingAPictureRunsOnTheFilesLaneAtUserBlocking() async throws {
        let runner = RecordingRunner(), avatars = HomeChiefAvatars(muxHome: try Self.folder(), cache: try Self.folder(), files: runner)
        try await avatars.clearPicture(chief: "agent_mux")
        #expect(runner.recorded.count == 1)
        #expect(runner.recorded.allSatisfy { $0.0 == .files && $0.1 == .userBlocking })
    }
}
