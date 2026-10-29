import CmuxNextCompat

/// The category flags' writers and the keystroke-timing privacy gate (rule 5 of
/// plans/cmux-next/chrome-parity/p09-observability.md): ``TraceRuntime/categoryMask`` is the requested flags
/// without ``TraceCategories/keyTiming`` while any ``TraceRuntime/KeyTimingHold`` is set. Chrome turns on secure
/// event input for a focused password field (ui/base/cocoa/secure_password_input.mm); here that input also stops
/// key timing.
extension TraceRuntime {
    /// Replaces the requested category flags (launch defaults, `trace.start`, `trace.stop`) and mirrors what
    /// records into the attached ring's header `categories` (trace.md "Header": mirrored on each change). The
    /// key category stays off while the keystroke-timing gate is closed (``setKeyTimingSuppressed(_:by:)``).
    public func setCategoryMask(_ mask: UInt64) {
        requestedFlags.store(mask, ordering: .sequentiallyConsistent)
        publishCategories()
    }

    /// The category flags last asked for, before the keystroke-timing gate.
    public var requestedCategoryMask: UInt64 { requestedFlags.load(ordering: .sequentiallyConsistent) }

    /// Closes (`true`) or releases `hold`'s part of the keystroke-timing gate
    /// (plans/cmux-next/chrome-parity/p09-observability.md rule 5, task 128). While any hold is set, no record of
    /// ``TraceCategories/keyTiming`` is written, in the black box or a recording, whatever `trace.start` asked
    /// for. Each source owns its bit, so releasing one never reopens the gate another still holds. A call that
    /// changes nothing returns after one load (the per-key-down sample of ``KeyTimingHold/secureEventInput``).
    public func setKeyTimingSuppressed(_ suppressed: Bool, by hold: KeyTimingHold) {
        var current = keyTimingHoldBits.load(ordering: .sequentiallyConsistent)
        // wakeup-allow: bounded: a compare-exchange retry; it loops only when another source changed its bit in between.
        while true {
            let desired = suppressed ? current | hold.rawValue : current & ~hold.rawValue
            guard desired != current else { return }
            let (exchanged, original) = keyTimingHoldBits.compareExchange(
                expected: current, desired: desired, ordering: .sequentiallyConsistent)
            if exchanged { break }
            current = original
        }
        publishCategories()
    }

    /// The holds that keep the keystroke-timing gate closed now (empty: open).
    public var keyTimingHolds: KeyTimingHold {
        KeyTimingHold(rawValue: keyTimingHoldBits.load(ordering: .sequentiallyConsistent))
    }

    /// Whether the keystroke-timing gate is closed: one relaxed load, read by the key emitters outside the ring
    /// (os_signpost, the MetricKit mirror, the typing probe) once per key.
    public var isKeyTimingSuppressed: Bool { keyTimingHoldBits.load(ordering: .relaxed) != 0 }

    /// Calls `observe` with the new ``categoryMask`` after each change of it (``setCategoryMask(_:)``, the
    /// keystroke-timing gate), on the thread that made the change, as Chrome's
    /// `TraceLog::AddEnabledStateObserver` does (base/trace_event/trace_log.h). An observer stays for the
    /// runtime's life.
    ///
    /// - Returns: false, and adds nothing, when the runtime has its four observers already.
    @discardableResult
    public func observeCategories(_ observe: @escaping @Sendable (_ mask: UInt64) -> Void) -> Bool {
        categoryObservers.add(observe)
    }

    /// Stores the flags for the current request and gate, and mirrors them into the ring header, again until
    /// neither input changed between its loads and both stores. A writer whose inputs change after its check
    /// publishes again itself, so the last store of both words is the current inputs' mask, with no lock.
    /// When the flags changed, the observers then hear the mask stored last.
    private func publishCategories() {
        var changed = false
        defer {
            if changed { categoryObservers.notify(categoryFlags.load(ordering: .sequentiallyConsistent)) }
        }
        // wakeup-allow: bounded: never waits; it stores again only when another writer changed the request or the gate between its loads and its check.
        while true {
            let requested = requestedFlags.load(ordering: .sequentiallyConsistent)
            let holds = keyTimingHoldBits.load(ordering: .sequentiallyConsistent)
            let mask = TraceCategories(rawValue: requested).gated(keyTimingSuppressed: holds != 0).rawValue
            if categoryFlags.exchange(mask, ordering: .sequentiallyConsistent) != mask { changed = true }
            // Sequentially consistent against attach's exchange and load: one of the two mirrors the new flags.
            let ringBits = UInt(ringAddress.load(ordering: .sequentiallyConsistent))
            UnsafeRawPointer(bitPattern: ringBits).map { Unmanaged<TraceRing>.fromOpaque($0) }?
                ._withUnsafeGuaranteedRef { $0.mirrorCategories(mask) }
            mirrorBlockingCalls(mask)
            if requestedFlags.load(ordering: .sequentiallyConsistent) == requested,
               keyTimingHoldBits.load(ordering: .sequentiallyConsistent) == holds {
                return
            }
        }
    }
}
