import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextMemory
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// The warm set grows only when hidden surfaces can let their GPU memory go, the
/// larger capacity reaches the sliced pressure release (`WarmSetRelease`), and the
/// surface ledger says which terminals are away (hidden, outside the keep-alive band).
@MainActor @Suite(.serialized) struct WarmSetGPUBudgetTests {
    @Test func theWarmSetGrowsOnlyWithTheGPURelease() {
        func warm(gib: UInt64, release: Bool) -> Int {
            SubsystemBudget.forMemory(physicalBytes: gib << 30, gpuResidentAvailable: release).warmTerminalSurfaces
        }
        #expect(warm(gib: 16, release: true) == 16)
        // Without the release API, the size it had before: min(24, max(8, MiB / 64 / 48)).
        #expect(warm(gib: 16, release: false) == 8)
        #expect(warm(gib: 64, release: false) == 21)
        #expect(warm(gib: 8, release: false) == 8)
        #expect(warm(gib: 64, release: true) == 32)
        // The same as the warm set's old formula, so a cache without the release keeps its size.
        #expect(SubsystemBudget.forThisMac(gpuResidentAvailable: false).warmTerminalSurfaces == WarmSetBudget.standard.terminalCapacity)
    }

    /// The cache's normal capacity is the budget's, for its ledger, its last frames and the sliced release,
    /// which scales it under pressure and closes one surface per slice.
    @Test func theSlicedReleaseScalesTheCachesNormalCapacity() {
        for residency in [nil, RecordingResidency()] as [RecordingResidency?] {
            let cache = Self.cache(gpuResidency: residency)
            let normal = SubsystemBudget.forThisMac(gpuResidentAvailable: residency != nil).warmTerminalSurfaces
            #expect(cache.normalWarmCapacity == normal)
            #expect(cache.ledger.capacity == normal)
            #expect(cache.warmBudget.terminalCapacity == normal)
            #expect(cache.lastFrames.capacity == normal)

            let coordinator = MemoryCoordinator(pressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), slicer: NoSlices())
            let warm = WarmSetRelease(host: cache, normalCapacity: cache.normalWarmCapacity, registry: coordinator)
            warm.updateMemoryLimit(MemoryLimit(percent: 50))
            #expect(cache.warmBudget.terminalCapacity == MemoryLimit(percent: 50).scale(normal))
            warm.updateMemoryLimit(.criticalThreshold)
            #expect(cache.warmBudget.terminalCapacity == 0)
            #expect(cache.ledger.capacity == normal, "the limit's turn closed surfaces; the release slices do")
            warm.updateMemoryLimit(.default)
            #expect(cache.warmBudget.terminalCapacity == normal)
            #expect(cache.ledger.capacity == normal)
        }
    }

    /// The cache's ledger drives each terminal's away state: the keep-alive band never changes its
    /// residency, hidden releases it, shown makes it resident; `debug.memory` counts no swap chain of a
    /// released surface and the two non-presented buffers of a resident hidden one.
    @Test func theCacheReleasesHiddenTerminalsAndDebugMemoryCountsNone() throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        let cache = services.cache
        let residency = RecordingResidency()
        let released = ScriptedTerminalIO(), resident = ScriptedTerminalIO()
        defer {
            released.finish()
            resident.finish()
        }
        // `released` has the switch; `resident` has none (terminalGPURelease off), so it keeps its GPU memory.
        cache.terminals["released"] = try Self.entry(services, surface: 1, io: released, gpuResidency: residency)
        cache.terminals["resident"] = try Self.entry(services, surface: 2, io: resident, gpuResidency: nil)
        let pane = Pane(), other = Pane()

        cache.present("released", by: pane, presence: .visible)
        cache.present("resident", by: other, presence: .visible)
        #expect(residency.calls.isEmpty)

        cache.setPresence(.keepAlive, presenter: pane)
        #expect(residency.calls.isEmpty, "the keep-alive band changed GPU residency: \(residency.calls)")
        #expect(!cache.ledger.isAway("released"))

        cache.setPresence(.hidden, presenter: pane)
        cache.setPresence(.hidden, presenter: other)
        #expect(residency.calls == [false], "hidden: \(residency.calls)")
        let releasedSession = try #require(cache.terminals["released"]?.session)
        let residentSession = try #require(cache.terminals["resident"]?.session)
        #expect(releasedSession.releasesGPUWhilePaused && residentSession.releasesGPUWhilePaused)
        #expect(releasedSession.pausedNonvolatileIOSurfaceBytes == 0)
        let residentBytes = residentSession.pausedNonvolatileIOSurfaceBytes
        #expect(residentBytes > 0, "a resident hidden surface counts no swap chain")

        let model = AppMemoryModel(services: services, budget: .forThisMac(gpuResidentAvailable: true))
        #expect(model.memoryTerminal.hiddenNonvolatileIOSurfaceBytes == Int(residentBytes))
        let control = DebugMemoryControl(services: services, budget: .forThisMac(gpuResidentAvailable: true))
        let snapshot = try #require(control.snapshot())
        let data = try MemoryDiagnosticsReport(snapshot: snapshot, processes: MemoryDiagnosticsProcesses(rows: [])).jsonData()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let terminal = try #require(json["terminal"] as? [String: Any])
        #expect((terminal["hidden_nonvolatile_iosurface_bytes"] as? Int) == Int(residentBytes))

        // The resident one closes (its tab closed): only the released one is left, at 0.
        cache.release("resident")
        #expect(AppMemoryModel(services: services, budget: .forThisMac(gpuResidentAvailable: true)).memoryTerminal.hiddenNonvolatileIOSurfaceBytes == 0)

        cache.setPresence(.visible, presenter: pane)
        #expect(residency.calls == [false, true], "shown: \(residency.calls)")
        #expect(!releasedSession.releasesGPUWhilePaused)
        withExtendedLifetime((services, pane, other)) {}
    }

    @Test func theLedgerReportsTerminalsThatGoAwayAndComeBack() {
        var ledger = SurfaceLedger<String, Int>(capacity: 4)
        #expect(ledger.present("a", by: 1, presence: .visible).away.isEmpty, "a shown tab was never away")
        #expect(!ledger.isAway("a"))

        var effects = ledger.setPresence(.keepAlive, owner: 1)
        #expect(effects.away.isEmpty, "the keep-alive band is not away: \(effects.away)")
        #expect(effects.rendering == ["a": false])

        effects = ledger.setPresence(.hidden, owner: 1)
        #expect(effects.away == ["a": true])
        #expect(ledger.isAway("a"))

        effects = ledger.setPresence(.visible, owner: 1)
        #expect(effects.away == ["a": false])
        #expect(effects.rendering == ["a": true])
        #expect(!ledger.isAway("a"))

        effects = ledger.withdraw("a", by: 1)
        #expect(effects.away == ["a": true], "a tab no pane presents is away")
    }

    @Test func anEvictedTerminalIsNoLongerReportedAway() {
        var ledger = SurfaceLedger<String, Int>(capacity: 1)
        _ = ledger.present("a", by: 1, presence: .hidden)
        #expect(ledger.isAway("a"))
        let effects = ledger.setCapacity(0)
        #expect(effects.evicted == ["a"])
        #expect(effects.away["a"] == nil)
        #expect(!ledger.isAway("a"))
    }

    // MARK: Fixtures

    /// A stand-in for the libghostty switch: each call's value.
    final class RecordingResidency: TerminalGPUResidency {
        var calls: [Bool] = []
        func setResident(_ resident: Bool, of view: TerminalSurfaceView) { calls.append(resident) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// Never runs a slice: these tests call the release consumer themselves.
    final class NoSlices: MemoryReleaseSlicer {
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {}
    }

    private static func cache(gpuResidency: (any TerminalGPUResidency)?) -> TabContentCache {
        TabContentCache(daemon: DaemonService(),
                        chromium: ChromiumEngineSlot(CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: InputEventTap())),
                        fileInput: NoFileInput(), mainWork: MainWorkScheduler(budget: MainFrameBudget()), gpuResidency: gpuResidency)
    }

    /// A terminal of the cache on a scripted IO, as `TabContentCache` makes one for a daemon tab.
    private static func entry(_ services: AppServices, surface: UInt64, io scripted: ScriptedTerminalIO,
                              gpuResidency: (any TerminalGPUResidency)?) throws -> TerminalEntry {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: surface), title: "~"))
        let session = TerminalSession(io: scripted, mainWork: MainWorkScheduler(budget: MainFrameBudget()), gpuResidency: gpuResidency)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let attachment = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                  visible: false, connection: { throw CancellationError() })
        return TerminalEntry(validity: "test", session: session, io: io, themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tab),
                             store: services.daemon.store, surface: tab.surface, mainWork: services.mainWork)
    }
}
