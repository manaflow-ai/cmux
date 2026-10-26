@testable import CmuxNextCloud
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): disk and Keychain calls that
/// a main-actor caller awaits run on the app's lanes, never on the caller's thread: the Cloud install key (a token
/// mint awaits it) and the bundled cmux-tui's version file (the Install confirmation and each SSH connect read it).
@Suite(.timeLimit(.minutes(1))) struct InstallKeyLaneTests {
    /// The lanes of the first `count` items `work` ran.
    static func first(_ count: Int, of lanes: AsyncStream<BlockingLane>) async -> [BlockingLane] {
        var seen: [BlockingLane] = []
        for await lane in lanes {
            seen.append(lane)
            if seen.count == count { break }
        }
        return seen
    }

    @Test func theFileInstallKeyIsReadWrittenAndRotatedOnTheFilesLane() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "install-key-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let (lanes, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.install-key", onRan: { lane, _, _, _ in ran.yield(lane) })
        let signer = MacInstallStore.files(directory: root, work: work).signer(for: "stack-user-1")

        let made = try await signer.publicKeyX963()
        let read = try await signer.publicKeyX963()
        try await signer.rotate()
        let rotated = try await signer.publicKeyX963()

        #expect(made.count == 65)
        #expect(read == made)
        #expect(rotated != made)
        #expect(await Self.first(4, of: lanes) == [.files, .files, .files, .files])
    }

    @Test func theBundledCommitIsReadOnTheFilesLane() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bundled-tui-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commit = String(repeating: "ab", count: 20)
        try Data("mode=pinned\ncommit=\(commit)\n".utf8).write(to: root.appending(path: "cmux-tui.version"))
        let (lanes, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.bundled-tui", onRan: { lane, _, _, _ in ran.yield(lane) })

        #expect(await BundledCmuxTUI.commit(binary: root.appending(path: "cmux-tui"), on: work) == commit)
        #expect(await Self.first(1, of: lanes) == [.files])
    }
}
