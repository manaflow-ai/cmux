public import CoreFoundation

extension MainRunLoopObserver {
    /// What a run loop's `CFCopyDescription` prints as the context of an observer made by
    /// ``afterCommitObserver(activities:repeats:order:_:)``: `context = cmux.drawsNothingAfterCommit`.
    /// The commit-boundary audit (`CommitBoundaryAudit`, `debug.commit_boundary`) does not count an
    /// observer with this context as late.
    public nonisolated static var drawsNothingAfterCommitContext: String { "cmux.drawsNothingAfterCommit" }

    /// A run-loop observer for after the Core Animation commit (an order past 2,000,000) whose
    /// handler lays out, displays and commits nothing: it reads the clock, stamps a heartbeat or
    /// keeps the cursor. A block observer's dump names only a trampoline
    /// (`__CFRunLoopObserverWithHandlerPerform`), so nothing in it tells such an observer from one that
    /// draws. This one's context describes itself as ``drawsNothingAfterCommitContext``, so the
    /// observer says what it is wherever it runs. No registry is involved.
    ///
    /// It is not added to any run loop: the caller adds it, and removes or invalidates it, as it would
    /// one from `CFRunLoopObserverCreateWithHandler`.
    ///
    /// ```swift
    /// let last = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: .max) { _ in
    ///     MainActor.assumeIsolated { passEnded() } // main-proof: added to the main run loop only
    /// }
    /// CFRunLoopAddObserver(CFRunLoopGetMain(), last, .commonModes)
    /// ```
    ///
    /// - Parameters:
    ///   - activities: The run loop stages that call `handler`.
    ///   - repeats: False to call `handler` once. Default true.
    ///   - order: Where `handler` runs among the observers of the same stage, lowest first.
    ///   - handler: The work, on the thread of the run loop the observer is added to.
    public nonisolated static func afterCommitObserver(
        activities: CFRunLoopActivity,
        repeats: Bool = true,
        order: CFIndex,
        _ handler: @escaping (CFRunLoopActivity) -> Void
    ) -> CFRunLoopObserver {
        let box = AfterCommitHandler(handler)
        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<AfterCommitHandler>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<AfterCommitHandler>.fromOpaque(info).release()
            },
            copyDescription: { _ in
                // The Copy rule: CF releases what this returns. Literal: a C callback captures nothing.
                Unmanaged.passRetained("cmux.drawsNothingAfterCommit" as CFString)
            }
        )
        // CF retains `info` through the context's retain while the observer lives; `box` is released here.
        return CFRunLoopObserverCreate(kCFAllocatorDefault, activities.rawValue, repeats, order, { _, activity, info in
            guard let info else { return }
            Unmanaged<AfterCommitHandler>.fromOpaque(info).takeUnretainedValue().handler(activity)
        }, &context)
    }
}

/// The handler of an ``MainRunLoopObserver/afterCommitObserver(activities:repeats:order:_:)``
/// observer, held by the observer's context.
private nonisolated final class AfterCommitHandler {
    let handler: (CFRunLoopActivity) -> Void

    init(_ handler: @escaping (CFRunLoopActivity) -> Void) {
        self.handler = handler
    }
}
