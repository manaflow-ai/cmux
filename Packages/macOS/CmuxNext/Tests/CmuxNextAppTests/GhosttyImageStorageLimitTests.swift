import CmuxNextCompat
import CmuxNextMemory
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// The app Ghostty's `image-storage-limit` is a bounded 5,000,000 per screen; with
/// `memorySmallAppStores` it comes from `SubsystemBudget.kittyImageBytesPerSurface` (5,000,000 on a 16 GB Mac) and
/// halves below normal memory pressure, rising again only after the coordinator's rise delay.
@MainActor
@Suite("Ghostty image storage limit", .serialized)
struct GhosttyImageStorageLimitTests {
    /// The budgets the budget applied, in order (each one config reload in the app).
    @MainActor private final class Reloads {
        var budgets: [Int] = []
    }

    private static func budget(gigabytes: UInt64) -> Int {
        SubsystemBudget.forMemory(physicalBytes: gigabytes << 30, gpuResidentAvailable: false).kittyImageBytesPerSurface
    }

    @Test func cmuxUsesABoundedViewerDefault() throws {
        #expect(try resolvedLimit("", bytes: Self.budget(gigabytes: 16)) == 5_000_000)
    }

    @Test func theDefaultIsSizedFromTheMacsMemory() throws {
        #expect(try resolvedLimit("", bytes: Self.budget(gigabytes: 8)) == 2_500_000)
        #expect(try resolvedLimit("", bytes: Self.budget(gigabytes: 64)) == 10_000_000)
    }

    @Test func userConfigOverridesTheCmuxDefault() throws {
        #expect(try resolvedLimit("image-storage-limit = 1234567\n", bytes: Self.budget(gigabytes: 16)) == 1_234_567)
    }

    @Test func aBudgetNeverTurnsTheKittyProtocolOff() {
        #expect(GhosttyRuntime.imageStorageLine(bytes: 0) == "image-storage-limit = 1")
        #expect(GhosttyRuntime.imageStorageLine(bytes: Int.max) == "image-storage-limit = \(UInt32.max)")
    }

    /// A budget on a hand-fired deadline rig, recording each budget it applies.
    private static func budget(_ fullBytes: Int, rig: MainDeadlineRig, reloads: Reloads) -> GhosttyImageStorageBudget {
        GhosttyImageStorageBudget(fullBytes: fullBytes,
                                  riseDeadline: MainDeadline(owner: "test.kitty-images.rise", workClass: .background, scheduler: rig.deadlines),
                                  riseDelay: MemoryCoordinator.limitRiseDelay) { reloads.budgets.append($0) }
    }

    @Test func theBudgetHalvesBelowNormalPressureAndComesBackAfterTheRiseDelay() {
        let rig = MainDeadlineRig(), reloads = Reloads()
        let storage = Self.budget(Self.budget(gigabytes: 16), rig: rig, reloads: reloads)
        storage.levelDidChange(.normal)
        #expect(reloads.budgets.isEmpty, "the full budget is the one the first config built with")
        storage.levelDidChange(.warning)
        storage.levelDidChange(.critical)
        #expect(reloads.budgets == [2_500_000], "one reload per budget change, none from warning to critical")
        storage.levelDidChange(.normal)
        #expect(reloads.budgets == [2_500_000], "the budget rises only once the level stayed normal")
        rig.advance(by: .seconds(29))
        rig.fireAtNow()
        #expect(reloads.budgets == [2_500_000])
        rig.fireAndRun()
        #expect(reloads.budgets == [2_500_000, 5_000_000])
        #expect(GhosttyImageStorageBudget(fullBytes: 1, riseDeadline: MainDeadline(owner: "test", workClass: .background, scheduler: rig.deadlines),
                                          riseDelay: .seconds(30)) { _ in }.budget(at: .critical) == 1, "never 0")
    }

    /// macOS WARN flaps: warning, normal, warning within the rise delay is one reload, not three.
    @Test func aWarningFlapWithinTheRiseDelayAppliesOnce() {
        let rig = MainDeadlineRig(), reloads = Reloads()
        let storage = Self.budget(Self.budget(gigabytes: 16), rig: rig, reloads: reloads)
        for _ in 0..<5 {
            storage.levelDidChange(.warning)
            rig.advance(by: .seconds(5))
            rig.fireAtNow()
            storage.levelDidChange(.normal)
            rig.advance(by: .seconds(5))
            rig.fireAtNow()
        }
        storage.levelDidChange(.warning)
        rig.fireAndRun()
        #expect(reloads.budgets == [2_500_000], "a flap reloaded every terminal's config: \(reloads.budgets)")
        #expect(rig.deadlines.nextFire == nil, "a rise stayed armed after the level fell again")
    }

    @Test func theBudgetFollowsTheCoordinatorsLevelFromItsCurrentOne() {
        let rig = MainDeadlineRig(), reloads = Reloads(), source = VoteSource()
        source.set(.warning)
        let storage = Self.budget(Self.budget(gigabytes: 16), rig: rig, reloads: reloads)
        storage.follow(source)
        #expect(reloads.budgets == [2_500_000], "the current level applies at once")
        source.set(.critical)
        source.set(.normal)
        rig.fireAndRun()
        #expect(reloads.budgets == [2_500_000, 5_000_000])
    }

    /// With `memorySmallAppStores` off the app keeps the bounded 5,000,000 per screen on every Mac.
    @Test func theStartingBudgetIsTheFixedDefaultUnlessTheFeatureSizesIt() {
        #expect(GhosttyImageStorageBudget.startingBytes(memoryBudget: Self.budget(gigabytes: 8), sizedFromMemory: false) == 5_000_000)
        #expect(GhosttyImageStorageBudget.startingBytes(memoryBudget: Self.budget(gigabytes: 64), sizedFromMemory: false) == 5_000_000)
        #expect(GhosttyImageStorageBudget.startingBytes(memoryBudget: Self.budget(gigabytes: 8), sizedFromMemory: true) == 2_500_000)
        #expect(GhosttyImageStorageBudget.startingBytes(memoryBudget: 0, sizedFromMemory: true) == 1, "never 0")
    }

    /// The runtime's own build path is bounded before the app sets a budget, and follows the budget it sets.
    @Test func theRuntimesConfigBuildIsBoundedFromTheStart() throws {
        let runtime = GhosttyRuntime()
        #expect(runtime.configInputs(theme: nil).imageStorageBytes == 5_000_000)
        #expect(try resolvedLimit("", inputs: runtime.configInputs(theme: nil)) == 5_000_000)
        runtime.setImageStorageBytesPerScreen(2_500_000)
        #expect(try resolvedLimit("", inputs: runtime.configInputs(theme: nil)) == 2_500_000)
    }

    private func resolvedLimit(_ text: String, bytes: Int) throws -> UInt32 {
        var inputs = GhosttyConfigInputs.testing(configFile: "")
        inputs.imageStorageBytes = bytes
        return try resolvedLimit(text, inputs: inputs)
    }

    /// The limit `inputs` resolve with `text` as their one config file.
    private func resolvedLimit(_ text: String, inputs: GhosttyConfigInputs) throws -> UInt32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-image-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        var inputs = inputs
        inputs.configFile = file.path
        let built = try #require(inputs.buildConfig())
        defer { built.free() }
        let config = try #require(built.config)
        var value: UInt32 = 0
        #expect(GhosttyRuntime.configGet(config, &value, key: "image-storage-limit"))
        return value
    }
}

/// The coordinator's side as a test drives it: a level and its change handlers.
@MainActor
private final class VoteSource: MemoryPressureVoteSource {
    private let handlers = MainActorHandlers<MemoryPressureLevel>()
    private(set) var pressureVote: MemoryPressureLevel = .normal

    func set(_ level: MemoryPressureLevel) {
        guard level != pressureVote else { return }
        pressureVote = level
        handlers.call(level)
    }

    func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel> {
        handlers.add(handler)
    }
}
