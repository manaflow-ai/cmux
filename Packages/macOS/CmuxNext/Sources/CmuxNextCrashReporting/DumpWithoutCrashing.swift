public import CmuxNextTrace
public import CmuxNextWakeups

/// The crash keys of one invariant report, read on the reporting thread at the report
/// (p09-observability-130): `Invariant.dumpWithoutCrashing` at a Release invariant site, and the
/// notFatalUntil / dumpWillBeCheck tiers, send the stack and these keys as one non-fatal event.
///
/// Chrome's `base::debug::DumpWithoutCrashing` (base/debug/dump_without_crashing.cc) has Crashpad write a
/// minidump of the live process, so the dump carries the crash keys as they are at the call
/// (components/crash/core/common/crash_key.h). cmux reads them the same way: the keys are read in the failing
/// call, before the event goes to the crash-reporting lane, because a scoped key (the running action, the main
/// task's owner) is put back as soon as its scope returns. Reading is relaxed loads of the
/// ``CmuxNextWakeups/CrashKeySlots`` words and one copy of the attached ``CmuxNextTrace/CrashKeyPage``: no lock,
/// no I/O. The tags are made on the lane.
///
/// ```swift
/// InvariantSink.install(reporter: reporter, bundleVersion: version, crashKeys: services.crashKeys)
/// Invariant.dumpWithoutCrashing("focus-machine-refused") // its event has crash_key.action_id, ...
/// ```
public struct InvariantCrashKeys: Sendable, Equatable {
    /// The app's single-word keys and hung threads.
    public let slots: CrashKeySlots.Snapshot
    /// The crash-key page, nil before the composition root attached one.
    public let page: CrashKeyPage.Snapshot?

    /// The keys of `keys` now. Call on the reporting thread.
    public init(_ keys: CrashKeySlots) {
        self.init(slots: keys.snapshot(), page: keys.page.page?.snapshot())
    }

    /// Keys read before (tests).
    public init(slots: CrashKeySlots.Snapshot, page: CrashKeyPage.Snapshot?) {
        self.slots = slots
        self.page = page
    }

    /// The keys as an event's tags (`crash_key.<name>`): the page's single-word keys, then the slots' keys.
    /// Keys at 0 are left out. Allocates: call on the lane.
    public var tags: [String: String] {
        (page?.tags ?? [:]).merging(slots.tags) { _, slot in slot }
    }
}
