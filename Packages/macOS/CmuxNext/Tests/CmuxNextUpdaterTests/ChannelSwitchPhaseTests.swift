import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// state-audit U1: a switch's phases reach `channelSwitchPhase` in order, and
/// none lands after the switch finished (a late download progress callback
/// used to hop to the main actor after completion and leave a stuck phase).
@MainActor
@Suite struct ChannelSwitchPhaseTests {
    struct NoInstalledApp: InstalledAppLocating {
        func applicationURLs(bundleIdentifier: String) -> [URL] { [] }
    }

    /// Returns at once and reports progress late, as a URL session's delegate can.
    struct LateProgressDownloader: AppChannelDownloading {
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
            Task.detached {
                try? await Task.sleep(for: .milliseconds(30))
                progress(0.5)
            }
        }
    }

    struct FailingMounter: DiskImageMounting {
        struct Failure: Error {}
        func attach(_ image: URL) async throws -> URL { throw Failure() }
        func detach(_ mountPoint: URL) async {}
    }

    @Test func noPhaseLandsAfterTheSwitchFinished() async throws {
        let defaults = UserDefaults(suiteName: "cmux-next-switch-phase-\(UUID().uuidString)")!
        let switcher = AppChannelSwitcher(locator: NoInstalledApp(), downloader: LateProgressDownloader(), mounter: FailingMounter(),
                                          temporaryDirectory: FileManager.default.temporaryDirectory)
        let service = UpdaterService(identity: AppcastFixtures.identity(), policy: ManagedUpdatePolicy { false },
                                     defaults: defaults, switcher: switcher, enableSparkle: false)
        let target = try #require(service.identity.channelSwitchTarget)
        let task = try service.switchChannel(to: target)
        let failure = await task.value
        #expect(failure != nil, "the fake mount fails the switch")
        #expect(service.channelSwitchPhase == nil)
        // The late progress callback fires after the switch returned.
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<20 { await Task.yield() }
        #expect(service.channelSwitchPhase == nil, "a finished switch shows no phase")
    }
}
