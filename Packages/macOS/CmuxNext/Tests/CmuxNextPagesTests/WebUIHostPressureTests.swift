import AppKit
import CmuxNextCompat
import CmuxNextMemory
@testable import CmuxNextPages
import Testing

/// Every web object follows memory pressure on one path, the app's memory coordinator
/// (p13-webui-047): ``WebUIHost`` registers its preload slot as a spare, next to Chromium's spare
/// windows (`ChromiumWarmup`), and the critical limit runs the one urgent discard pass over tabs,
/// chats and pages (`BrowserHibernation`). The drop order is Chrome's cheapest memory first: at
/// warning the slot and the spares go in the level's turn; at critical they go in that turn too and
/// the ranked pass runs once, on the coordinator's next release slice, after them. The host follows
/// the coordinator's level, so the debug override (`debug.hibernation.pressure`) drops the slot too.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct WebUIHostPressureTests {
    typealias FakePage = PagePreloadSlotTests.FakePage
    typealias FakeParking = PagePreloadSlotTests.FakeParking

    /// Stands in for the browser hibernation's registration: a lossy consumer with its traits
    /// (`BrowserHibernation.memoryTraits`, checked in `BrowserHibernationPressureTests`) whose
    /// critical release slice is the urgent ranked pass.
    @MainActor final class RankedPassConsumer: MemoryConsumer {
        static let traits = MemoryConsumerTraits(
            estimatedUsage: .large, dataAccess: .reads, retention: .lossy, recreateCost: .expensive,
            releaseCPUCost: .high, isStateful: false, supportsMemoryLimit: false)
        let log: DropLog
        var registration: MemoryConsumerRegistration?

        init(log: DropLog, registry: any MemoryConsumerRegistry) {
            self.log = log
            registration = MemoryConsumerRegistration(name: "browser-hibernation", traits: Self.traits, consumer: self, registry: registry)
        }

        func updateMemoryLimit(_ limit: MemoryLimit) {}

        func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
            if slice.limit.isCritical { log.entries.append("ranked pass") }
            return .done
        }

        var memoryUsage: MemoryUsage? { nil }
    }

    /// What went, in order.
    @MainActor final class DropLog {
        var entries: [String] = []
    }

    /// The pressure path as the app wires it: the host first (AppServices builds it before the
    /// warmup), then Chromium's spare windows, then the urgent discard pass.
    struct Rig {
        let memory: PageTestMemory
        let log: DropLog
        let deadlines: LifecycleDeadlineRig
        let host: WebUIHost
        let slot: PagePreloadSlot
        let page: FakePage
        let spareWindows: SpareMemoryConsumer
        let rankedPass: RankedPassConsumer

        init() {
            let memory = PageTestMemory(), log = DropLog(), deadlines = LifecycleDeadlineRig()
            let host = WebUIHost(chromium: nil, openPanel: nil, memory: memory.coordinator)
            let slot = PagePreloadSlot(parkState: .frozenHidden, deadlines: deadlines.scheduler) { move, _ in
                if move == .drop { log.entries.append("preload slot") }
            }
            host.preload = slot
            spareWindows = SpareMemoryConsumer(name: "chromium-spare-windows", registry: memory.coordinator, spares: { 1 },
                                               drop: { log.entries.append("spare windows") }, refill: {})
            rankedPass = RankedPassConsumer(log: log, registry: memory.coordinator)
            let page = FakePage("newTab")
            slot.preload(PagePreloadSlotTests.newTab, size: PagePreloadSlotTests.size, in: FakeParking()) { _ in page }
            page.paint()
            page.cover()
            self.memory = memory
            self.log = log
            self.deadlines = deadlines
            self.host = host
            self.slot = slot
            self.page = page
        }
    }

    @Test func warningDropsTheSlotAndTheSparesButRunsNoPass() {
        let rig = Rig()
        #expect(rig.slot.count == 1)
        rig.memory.send(.warning)
        #expect(rig.log.entries == ["preload slot", "spare windows"])
        #expect(rig.page.closed)
        #expect(!rig.slot.allowsPreload)
        rig.memory.runSlices()
        #expect(rig.log.entries == ["preload slot", "spare windows"], "warning ran the urgent discard pass")
    }

    @Test func criticalDropsTheSlotAndTheSparesThenRunsOneRankedPass() {
        let rig = Rig()
        rig.memory.send(.critical)
        #expect(rig.log.entries == ["preload slot", "spare windows"], "the ranked pass ran in the pressure event's turn")
        rig.memory.runSlices()
        #expect(rig.log.entries == ["preload slot", "spare windows", "ranked pass"])
        rig.memory.send(.normal)
        #expect(rig.slot.allowsPreload)
        rig.memory.runSlices()
        #expect(rig.log.entries.filter { $0 == "ranked pass" }.count == 1)
    }

    @Test func warningThenCriticalRunsTheRankedPassAfterTheSlotWentAtWarning() {
        let rig = Rig()
        rig.memory.send(.warning)
        rig.memory.send(.critical)
        #expect(!rig.slot.allowsPreload)
        rig.memory.runSlices()
        #expect(rig.log.entries == ["preload slot", "spare windows", "ranked pass"])
    }

    /// The bug the move fixes: the host subscribed to the kernel's events, so the coordinator's debug
    /// override (`debug.hibernation.pressure critical`, D6's bench) left the preload slot full.
    @Test func theDebugOverrideDropsTheSlot() {
        let rig = Rig()
        rig.memory.coordinator.pressureOverride = .critical
        #expect(rig.slot.count == 0)
        #expect(rig.page.closed)
        #expect(rig.host.memoryLevel == .critical)
        rig.memory.coordinator.pressureOverride = nil
        #expect(rig.slot.allowsPreload)
        #expect(rig.host.memoryLevel == .normal)
    }

    @Test func anInstalledSlotStartsAtTheCurrentLevel() {
        let memory = PageTestMemory()
        memory.send(.warning)
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: memory.coordinator)
        let deadlines = LifecycleDeadlineRig()
        let slot = PagePreloadSlot(parkState: .frozenHidden, deadlines: deadlines.scheduler) { _, _ in }
        host.preload = slot
        #expect(!slot.allowsPreload)
        memory.send(.normal)
        #expect(slot.allowsPreload)
        withExtendedLifetime((host, deadlines)) {}
    }

    /// The host is one spare consumer in the memory report, holding the slot's one page.
    @Test func theHostRegistersOneSpareConsumer() {
        let rig = Rig()
        let report = rig.memory.coordinator.report(budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false))
        let rows = report.consumers.filter { $0.name == "webui-preload" }
        #expect(rows.count == 1)
        #expect(rows.first?.traits == SpareMemoryConsumer.traits)
        withExtendedLifetime(rig) {}
    }
}
