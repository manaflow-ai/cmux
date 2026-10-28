import CoreFoundation

/// The main run loop source the scheduler's work batch runs from (plans/cmux-next/sequence-manager-DESIGN.md
/// section 2.3; Chrome's `MessagePumpCFRunLoopBase::work_source_`, base/message_loop/message_pump_apple.mm): one
/// version-0 source in the common modes, so menu tracking, live resize, drag sessions and modal panels run the batch
/// too. ``signal()`` asks for one callout and wakes the run loop; signals before the callout runs are one callout, and
/// a signal made during it (a task posts) asks for the next one, which a run loop nested in the task runs.
///
/// The ``MainWorkScheduler`` makes it on its first turn: a scheduler that never posts, and a test that runs its own
/// turns (``MainWorkScheduler/TurnPerformer``), add nothing to the run loop. Released with its scheduler, it leaves
/// the run loop.
///
/// ```swift
/// let source = MainWorkBatchSource { [weak self] in self?.runPostedTurn() }
/// source.signal()   // one callout on a later turn of the main run loop, in any common mode
/// ```
@MainActor
final class MainWorkBatchSource {
    private let handle: Handle

    /// - Parameter perform: The batch: runs on the main thread in the source's callout, once per callout.
    init(perform: @escaping @MainActor () -> Void) {
        handle = Handle(target: Target(perform: perform))
    }

    /// Asks for one callout on a later turn of the main run loop and wakes it; never runs the batch inline.
    func signal() {
        CFRunLoopSourceSignal(handle.source)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// What the callout runs, held by ``Handle`` for the source's life.
    @MainActor
    private final class Target {
        let perform: @MainActor () -> Void

        init(perform: @escaping @MainActor () -> Void) {
            self.perform = perform
        }
    }

    /// Owns the source and its target: the source is on the main run loop from init until this is released, whose
    /// deinit takes it off before the target goes.
    private final class Handle {
        let source: CFRunLoopSource
        private let target: Target

        init(target: Target) {
            self.target = target
            var context = CFRunLoopSourceContext()
            // SAFETY: unretained; this Handle keeps `target` until its deinit has invalidated the source, so the source
            // never calls back with a released target.
            context.info = unsafe Unmanaged.passUnretained(target).toOpaque()
            context.perform = { info in
                guard let info else { return }
                // SAFETY: `info` is the target init gave, alive while its source is valid (above).
                let target = unsafe Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
                // main-proof: the source is only on CFRunLoopGetMain(), whose callouts run on the main thread.
                MainActor.assumeIsolated { target.perform() }
            }
            let source: CFRunLoopSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }

        deinit {
            CFRunLoopSourceInvalidate(source)
        }
    }
}
