import CmuxNextCompat
import CmuxNextMemory
import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// p07-memory-083: the app Ghostty's `image-storage-limit` comes from `SubsystemBudget.kittyImageBytesPerSurface`
/// (5,000,000 per screen on a 16 GB Mac, as the literal it replaces) and halves below normal memory pressure.
@MainActor
@Suite("Ghostty image storage limit", .serialized)
struct GhosttyImageStorageLimitTests {
    /// The budgets the consumer applied, in order (each one config reload in the app).
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

    @Test func theBudgetHalvesBelowNormalPressureAndComesBackAtNormal() {
        let reloads = Reloads()
        let storage = GhosttyImageStorageConsumer(fullBytes: Self.budget(gigabytes: 16)) { reloads.budgets.append($0) }
        storage.memoryLevelDidChange(.normal)
        #expect(reloads.budgets.isEmpty, "the full budget is the one the first config built with")
        storage.memoryLevelDidChange(.warning)
        storage.memoryLevelDidChange(.critical)
        #expect(reloads.budgets == [2_500_000], "one reload per budget change, none from warning to critical")
        storage.memoryLevelDidChange(.normal)
        #expect(reloads.budgets == [2_500_000, 5_000_000])
        #expect(storage.budget(at: .warning) >= 1)
        #expect(GhosttyImageStorageConsumer(fullBytes: 1) { _ in }.budget(at: .critical) == 1, "never 0")
    }

    @Test func theBudgetIsALossyConsumerThatFollowsTheLevel() {
        let traits = GhosttyImageStorageConsumer.memoryTraits
        #expect(traits.retention == .lossy && !traits.isManaged)
        #expect(GhosttyImageStorageConsumer(fullBytes: 1) { _ in }.memoryUsage == nil, "libghostty reports no image bytes")
    }

    private func resolvedLimit(_ text: String, bytes: Int) throws -> UInt32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-image-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        var inputs = GhosttyConfigInputs.testing(configFile: file.path)
        inputs.imageStorageBytes = bytes
        let built = try #require(inputs.buildConfig())
        defer { built.free() }
        let config = try #require(built.config)
        var value: UInt32 = 0
        #expect(GhosttyRuntime.configGet(config, &value, key: "image-storage-limit"))
        return value
    }
}
