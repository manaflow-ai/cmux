import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLaunch
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// With `memorySmallAppStores`, the launch reads of the last quit's terminal frames and agent pages
/// go once the launch settled and no agent page waits behind its last frame (`LaunchSettle.dropLaunchReads`), not at
/// their 30 s keep deadline. Without the feature they keep their deadline.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchSettleDropsLaunchReadsTests {
    /// The two launch reads, ended, with one decoded terminal frame and one decoded agent page each.
    private struct Reads {
        let frames: TerminalLaunchFrames
        let pages: AgentPaneLaunchImages
        let directories: [URL]

        func remove() {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private static func reads() async throws -> Reads {
        let frameDirectory = try await TerminalLaunchFrameTests.saved(
            ["tab-1": TerminalLaunchFrameTests.frame(TerminalLaunchFrameTests.size, scale: 2)])
        let pageDirectory = try await AgentPaneLaunchImageReadTests.saved(["tab_a"])
        let frames = await TerminalLaunchFrameTests.launch(frameDirectory)
        let pages = AgentPaneLaunchImages(directory: pageDirectory)
        await pages.prefetch(on: AgentPaneLaunchImageReadTests.work)?.value
        return Reads(frames: frames, pages: pages, directories: [frameDirectory, pageDirectory])
    }

    private static func features(smallAppStores: Bool) -> FeatureList {
        FeatureList(registry: FeatureRegistry(), channel: .dev,
                    overrides: FeatureOverrides(environmentEnabled: smallAppStores ? [Feature.memorySmallAppStores.name] : []))
    }

    private static func settle() -> LaunchSettle {
        LaunchSettle(reveal: LaunchReveal(deadline: .seconds(60)), paneRefs: VisiblePaneRefs(hold: { _ in { _ in } }, mainWork: MainWorkScheduler(budget: MainFrameBudget())))
    }

    @Test func theLaunchReadsGoOnceTheLaunchSettledAndNoAgentPageWaits() async throws {
        let reads = try await Self.reads()
        defer { reads.remove() }
        let scheduler = StartupTestScheduler()
        let images = LaunchImageHold(startup: scheduler.startup)
        let share = images.began()
        let settle = Self.settle()
        settle.dropLaunchReads(frames: reads.frames, pages: reads.pages, features: Self.features(smallAppStores: true), images: images)
        #expect(reads.frames.launchFrameCount == 1)
        #expect(reads.pages.memoryUsage?.entries == 1)
        settle.settle()
        #expect(reads.frames.launchFrameCount == 1, "an agent page still waits behind its last frame")
        #expect(reads.pages.memoryUsage?.entries == 1, "an agent page still waits behind its last frame")
        share.end(.visiblePaneLoadedIdle)
        #expect(reads.frames.launchFrameCount == 0, "a decoded terminal frame stayed after the settle")
        #expect(reads.frames.memoryUsage == .empty)
        #expect(reads.pages.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 0), "a decoded agent page stayed after the settle")
        #expect(reads.frames.prefetch(on: TerminalLaunchFrameTests.work) == nil, "no terminal frame read starts again")
        #expect(reads.pages.prefetch(on: AgentPaneLaunchImageReadTests.work) == nil, "no agent page read starts again")
    }

    @Test func withTheFeatureOffTheLaunchReadsKeepTheirDeadline() async throws {
        let reads = try await Self.reads()
        defer { reads.remove() }
        let images = LaunchImageHold()
        let settle = Self.settle()
        settle.dropLaunchReads(frames: reads.frames, pages: reads.pages, features: Self.features(smallAppStores: false), images: images)
        settle.settle()
        #expect(reads.frames.launchFrameCount == 1)
        #expect(reads.pages.memoryUsage?.entries == 1)
    }
}
