import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextUpdater
import Darwin
import Foundation
import Testing

/// Every action the user runs (a shortcut, the palette, a menu) reaches `UpdaterService.markTipActionUsed`
/// through the registry's run observer, on the key's own turn. An action that has no tip must cost nothing
/// there: before this, the check built the whole localized tips catalog (`TipCatalog.all`, 16 localized
/// string lookups) for every run of an action outside it, about 51 allocations per Cmd-T in Release
/// (KeyRouterBench on feat-cmux-next, fleet step 96f85fbd7ff004ea1e8aa21e). The tips behavior stays: an
/// action in the catalog is marked used once, and "Try It" runs only catalog actions.
@MainActor @Suite(.serialized)
struct TipActionRunAllocationTests {
    /// Runs counted per check.
    private static let runs = 256

    private func defaults() throws -> UserDefaults {
        let suite = "TipActionRunAllocationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func updater(_ defaults: UserDefaults) -> UpdaterService {
        let updater = UpdaterService(defaults: defaults, enableSparkle: false, recordsUpdates: false, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        updater.tipsEnabled = true
        return updater
    }

    @Test func anActionWithoutATipAllocatesNothing() throws {
        let updater = updater(try defaults())
        let action = "newTab"
        try #require(!TipCatalog.all.contains { $0.action == action }, "\(action) has a tip: the check needs an action without one")
        let control = TipRunMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        updater.markTipActionUsed(action) // warm-up outside the count: first-use statics and metadata
        // The same loop with nothing in it is the baseline (a Debug for-in can allocate per iteration).
        let loop = try #require(TipRunMallocProbe.allocations { for _ in 0..<Self.runs {} })
        let measured = try #require(TipRunMallocProbe.allocations {
            for _ in 0..<Self.runs { updater.markTipActionUsed(action) }
        })
        let allocations = measured - loop
        print("TIP-ACTION-RUN-ALLOCS \(allocations) in \(Self.runs) runs (loop alone: \(loop))")
        #expect(allocations == 0, "a run of \(action) made \(allocations) allocations in \(Self.runs) runs (loop alone: \(loop))")
        #expect(!TipState(defaults: updater.defaults).usedActions.contains(action))
    }

    /// The unlocalized action set the run path reads is the catalog's: a tip added to ``TipCatalog/all``
    /// without its action here would never be marked used.
    @Test func theActionSetIsTheCatalogs() {
        #expect(TipCatalog.actions == Set(TipCatalog.all.map(\.action)))
        #expect(TipCatalog.actions.count == TipCatalog.all.count, "two tips share an action")
    }

    @Test func aCatalogActionIsMarkedUsedOnce() throws {
        let defaults = try defaults()
        let updater = updater(defaults)
        let action = try #require(TipCatalog.all.first?.action)
        try #require(!TipState(defaults: defaults).usedActions.contains(action))
        updater.markTipActionUsed(action)
        let marked = TipState(defaults: defaults)
        #expect(marked.usedActions.contains(action))
        updater.markTipActionUsed(action)
        #expect(TipState(defaults: defaults) == marked, "a second run changed the saved tip state")
    }

    @Test func tryItRunsOnlyCatalogActions() throws {
        let inCatalog = try #require(TipCatalog.all.first?.action)
        let outside = "newTab"
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: ActionID(rawValue: inCatalog), title: "In", category: .other),
                                                ActionDescriptor(id: ActionID(rawValue: outside), title: "Out", category: .other)])
        var ran: [String] = []
        registry.bindEffect(ActionID(rawValue: inCatalog), effect: { _ in
            ran.append(inCatalog)
            return .done
        })
        registry.bindEffect(ActionID(rawValue: outside), effect: { _ in
            ran.append(outside)
            return .done
        })
        let updater = updater(try defaults())
        updater.attachTips(registry: registry)
        updater.runTipAction?(outside)
        #expect(ran.isEmpty, "Try It ran \(outside), which has no tip")
        updater.runTipAction?(inCatalog)
        #expect(ran == [inCatalog])
        #expect(TipState(defaults: updater.defaults).usedActions.contains(inCatalog), "the user's run of a tip's action did not mark it used")
    }
}

// MARK: Counting the main thread's allocations

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias TipRunMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private struct TipRunMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyTipRunMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == TipRunMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = TipRunMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body`, through libmalloc's `malloc_logger` hook
/// (as PageRouterSubscribeEndTests counts); nil when libmalloc exports no hook.
nonisolated private struct TipRunMallocProbe {
    static func allocations(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: TipRunMallocLogger?.self)
        TipRunMallocTally.allocations.store(0, ordering: .relaxed)
        TipRunMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyTipRunMalloc
        body()
        hook.pointee = previous
        TipRunMallocTally.thread.store(0, ordering: .relaxed)
        return TipRunMallocTally.allocations.load(ordering: .relaxed)
    }
}
