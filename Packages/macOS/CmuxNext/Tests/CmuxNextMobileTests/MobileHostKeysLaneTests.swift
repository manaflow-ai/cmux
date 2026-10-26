import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextMobile

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): the phone listener's
/// development key files are read and written on the app's files lane, never on the host actor's thread (a
/// cooperative pool thread) or its caller's.
@Suite(.timeLimit(.minutes(1))) struct MobileHostKeysLaneTests {
    @Test func theInstallationIDIsMadeOnceAndReadBackOnTheFilesLane() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mobile-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let (lanes, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.mobile-keys", onRan: { lane, _, _, _ in ran.yield(lane) })
        let configuration = MobileHostConfiguration(
            baseURL: try #require(URL(string: "https://example.invalid")), environment: "development", namespace: "com.example.test", tag: "test",
            stateDirectory: root, keyStorage: .files, displayName: "Test Mac", appVersion: "1", appBuild: "1",
            daemonSocketPath: { nil })
        let keys = MobileHostKeys(configuration: configuration, work: work)

        let made = try await keys.deviceID()
        let read = try await keys.deviceID()

        #expect(UUID(uuidString: made) != nil)
        #expect(read == made)
        var seen: [BlockingLane] = []
        for await lane in lanes {
            seen.append(lane)
            if seen.count == 2 { break }
        }
        #expect(seen == [.files, .files], "the key files were not read and written on the files lane")
    }
}
