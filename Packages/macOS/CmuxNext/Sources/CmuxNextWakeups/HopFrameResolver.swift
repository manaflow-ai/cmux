#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat

/// Picks the frame that names a hop's site from its resolved stack (``ImageOffsetResolver`` frames,
/// innermost first). Runs where the frames were resolved: the recorder's fold and the callout
/// sampler's queue, never the main thread.
struct HopFrameResolver {
    /// What one frame of a Swift hop's stack is to its site.
    enum FrameKind: Equatable {
        /// A frame of the image that calls the recorder's producer (the hook's caller,
        /// libswift_Concurrency): the frames before the first one are the hook's and the recorder's.
        case entry
        /// A frame the enqueue passes through, never a site (``runtimeImages``,
        /// ``runtimeSymbolPrefixes``).
        case runtime
        /// Any other frame, an unresolved one included: a site.
        case other
    }

    /// The image that calls a main-executor hook: `swift_task_enqueueMainExecutor`.
    static let concurrencyRuntime = MainJobRing.concurrencyRuntimeImage

    /// The frames a main-actor job's enqueue passes through between the hook and the code that
    /// enqueued it, never its site: the Swift concurrency runtime, the Swift core library,
    /// libdispatch and its Swift overlay, and the thread start below a worker's stack. The
    /// launch's main-job census names its enqueuers by the same table.
    static let runtimeImages = MainJobRing.enqueueRuntimeImages

    /// The mangled prefixes of the `Task` and `MainActor` members the compiler emits into the
    /// caller's image (`Task.init`, `MainActor.run`): not inlined in a DEBUG build, they would name
    /// every `Task { }` of a module as one site.
    static let runtimeSymbolPrefixes = MainJobRing.enqueueRuntimeSymbolPrefixes

    /// The frames a run-loop callout passes through between CFRunLoop's callout trampoline and the
    /// code it calls: the runtime images, Core Foundation, Foundation (`__NSFireTimer`) and the
    /// Objective-C runtime.
    static let calloutPassThroughImages: Set<String> = runtimeImages.union(["CoreFoundation", "Foundation", "libobjc.A.dylib"])

    /// What `frame` is to a Swift hop's site, when `entry` is the image that calls the producer.
    static func kind(_ frame: ImageOffsetResolver.Resolved?, entry: String) -> FrameKind {
        guard let frame else { return .other }
        if frame.image.name == entry { return .entry }
        if runtimeImages.contains(frame.image.name) { return .runtime }
        if let symbol = frame.nearestSymbol, runtimeSymbolPrefixes.contains(where: { symbol.hasPrefix($0) }) { return .runtime }
        return .other
    }

    /// The index of the frame that names a Swift hop's site: from the first ``FrameKind/entry``
    /// frame (the hook's and the recorder's own frames come before it, however many the optimizer
    /// left), the first ``FrameKind/other`` frame. Nil when no frame came from the entry image or
    /// none follows the runtime frames (the stack was cut there): the hop has no site.
    static func siteIndex(_ kinds: [FrameKind]) -> Int? {
        guard let entry = kinds.firstIndex(of: .entry) else { return nil }
        return kinds[entry...].firstIndex(of: .other)
    }

    /// The callout's site in a main-thread sample taken during a run-loop callout: from the
    /// innermost callout trampoline (`__CFRUNLOOP_IS_CALLING_OUT_TO_…`, `__CFRUNLOOP_IS_SERVICING_…`)
    /// inward, the first frame outside ``calloutPassThroughImages``. `swiftJob`: the callout ran a
    /// Swift job (a libswift_Concurrency frame between the two), whose enqueue the swift lane also
    /// names. Nil when the sample shows no trampoline or nothing inside it.
    static func calloutSite(_ frames: [ImageOffsetResolver.Resolved?]) -> (index: Int, swiftJob: Bool)? {
        guard let trampoline = frames.firstIndex(where: { $0?.nearestSymbol?.hasPrefix("__CFRUNLOOP_IS_") == true }),
              trampoline > 0 else { return nil }
        var swiftJob = false
        for index in stride(from: trampoline - 1, through: 0, by: -1) {
            guard let frame = frames[index] else { return (index, swiftJob) }
            if frame.image.name == concurrencyRuntime { swiftJob = true }
            if !calloutPassThroughImages.contains(frame.image.name) { return (index, swiftJob) }
        }
        return nil
    }
}
#endif
