import CmuxNextMemory
import Testing

/// The budget table of p07-memory.md section 3.B, as literals per Mac size.
struct SubsystemBudgetTests {
    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let gigabytes: UInt64
        let renderers: Int
        let warmWithGPURelease: Int
        let warmWithoutGPURelease: Int
        let parked: Int
        let imageMiB: Int
        let homeRenderMiB: Int
        let snapshotMiB: Int
        let agentPages: Int
        let internalPages: Int
        let kittyBytes: Int

        var testDescription: String { "\(gigabytes) GB" }
    }

    nonisolated static let table: [Row] = [
        Row(gigabytes: 8, renderers: 32, warmWithGPURelease: 8, warmWithoutGPURelease: 8, parked: 4,
            imageMiB: 64, homeRenderMiB: 128, snapshotMiB: 32, agentPages: 13, internalPages: 2,
            kittyBytes: 2_500_000),
        Row(gigabytes: 16, renderers: 64, warmWithGPURelease: 16, warmWithoutGPURelease: 8, parked: 8,
            imageMiB: 128, homeRenderMiB: 256, snapshotMiB: 64, agentPages: 27, internalPages: 4,
            kittyBytes: 5_000_000),
        Row(gigabytes: 24, renderers: 82, warmWithGPURelease: 24, warmWithoutGPURelease: 8, parked: 12,
            imageMiB: 192, homeRenderMiB: 256, snapshotMiB: 96, agentPages: 32, internalPages: 6,
            kittyBytes: 7_500_000),
        Row(gigabytes: 32, renderers: 82, warmWithGPURelease: 32, warmWithoutGPURelease: 10, parked: 16,
            imageMiB: 256, homeRenderMiB: 256, snapshotMiB: 128, agentPages: 32, internalPages: 8,
            kittyBytes: 10_000_000),
        Row(gigabytes: 64, renderers: 82, warmWithGPURelease: 32, warmWithoutGPURelease: 21, parked: 16,
            imageMiB: 512, homeRenderMiB: 256, snapshotMiB: 256, agentPages: 32, internalPages: 8,
            kittyBytes: 10_000_000),
        Row(gigabytes: 128, renderers: 82, warmWithGPURelease: 32, warmWithoutGPURelease: 24, parked: 16,
            imageMiB: 1024, homeRenderMiB: 256, snapshotMiB: 512, agentPages: 32, internalPages: 8,
            kittyBytes: 10_000_000),
    ]

    @Test(arguments: table)
    func budgetsFollowPhysicalMemory(_ row: Row) {
        let bytes = row.gigabytes << 30
        let budget = SubsystemBudget.forMemory(physicalBytes: bytes, gpuResidentAvailable: true)
        let withoutRelease = SubsystemBudget.forMemory(physicalBytes: bytes, gpuResidentAvailable: false)

        #expect(budget.physicalMiB == Int(row.gigabytes) * 1024)
        #expect(budget.chromiumRendererLimit == row.renderers)
        #expect(budget.warmTerminalSurfaces == row.warmWithGPURelease)
        #expect(withoutRelease.warmTerminalSurfaces == row.warmWithoutGPURelease)
        #expect(budget.parkedWorkspaces == row.parked)
        #expect(budget.parkedIdleTimeout == .seconds(900))
        #expect(budget.imageCacheBytes == row.imageMiB << 20)
        #expect(budget.homeRenderBitmapBytes == row.homeRenderMiB << 20)
        #expect(budget.hibernationSnapshotBytes == row.snapshotMiB << 20)
        #expect(budget.liveHiddenAgentPages == row.agentPages)
        #expect(budget.liveHiddenInternalPages == row.internalPages)
        #expect(budget.kittyImageBytesPerSurface == row.kittyBytes)
        #expect(budget.webProcessPagesPerGroup == 8)
    }

    @Test func onlyTheWarmSetDependsOnTheGPUReleaseAPI() {
        let with = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: true)
        let without = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)

        #expect(with.chromiumRendererLimit == without.chromiumRendererLimit)
        #expect(with.parkedWorkspaces == without.parkedWorkspaces)
        #expect(with.imageCacheBytes == without.imageCacheBytes)
        #expect(with.liveHiddenAgentPages == without.liveHiddenAgentPages)
        #expect(with.warmTerminalSurfaces != without.warmTerminalSurfaces)
    }

    /// A 16 GB Mac keeps at least the caps the subsystems hard-code today.
    @Test func sixteenGigabytesKeepTodaysCaps() {
        let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)
        let previewImageCache = 32 << 20
        let pageThumbnails = 16 << 20
        let tabThumbnailCache = 48 << 20
        let hibernationSnapshots = 64 << 20
        let ghosttyImageStorageLimit = 5_000_000
        let webProcessGroupPages = 8

        #expect(budget.imageCacheBytes >= previewImageCache + pageThumbnails + tabThumbnailCache)
        #expect(budget.hibernationSnapshotBytes >= hibernationSnapshots)
        #expect(budget.kittyImageBytesPerSurface >= ghosttyImageStorageLimit)
        #expect(budget.webProcessPagesPerGroup == webProcessGroupPages)
    }

    /// A Mac below the table still gets each subsystem's floor.
    @Test func smallMacsGetTheFloors() {
        let budget = SubsystemBudget.forMemory(physicalBytes: 2 << 30, gpuResidentAvailable: true)
        let withoutRelease = SubsystemBudget.forMemory(physicalBytes: 2 << 30, gpuResidentAvailable: false)

        #expect(budget.chromiumRendererLimit == 8)
        #expect(budget.warmTerminalSurfaces == 4)
        #expect(withoutRelease.warmTerminalSurfaces == 8)
        #expect(budget.parkedWorkspaces == 4)
        #expect(budget.homeRenderBitmapBytes == 64 << 20)
        #expect(budget.liveHiddenAgentPages == 4)
        #expect(budget.liveHiddenInternalPages == 2)
        #expect(budget.kittyImageBytesPerSurface == 2_500_000)

        let zero = SubsystemBudget.forMemory(physicalBytes: 0, gpuResidentAvailable: true)
        #expect(zero.chromiumRendererLimit == 3)
    }

    @Test func thisMacIsSizedFromItsPhysicalMemory() {
        let budget = SubsystemBudget.forThisMac(gpuResidentAvailable: true)

        #expect(budget.physicalMiB > 0)
        #expect((3...82).contains(budget.chromiumRendererLimit))
    }
}
