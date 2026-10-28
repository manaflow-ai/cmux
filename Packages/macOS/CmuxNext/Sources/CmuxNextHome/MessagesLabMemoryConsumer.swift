public import CmuxNextCompat
public import CmuxNextWakeups
public import MessagesLabHome
import MessagesLabSidebar

/// The Home transcript's process-wide pixel caches (row bitmaps, decoded media, long-text tiles and
/// bubble outlines, `MessagesLabTranscriptCaches`) and each Home list's row bitmaps as one lossless
/// consumer of the Mac's memory coordinator, with one byte budget
/// (`SubsystemBudget.homeRenderBitmapBytes`, which the caller passes).
///
/// Chrome registers each cache as a consumer where it is built (base/memory_coordinator/memory_consumer.h);
/// the MessagesLab package is shared with iOS and knows no CmuxNext type, so this adapter registers its
/// engine-neutral surface (`bytes`, `setBudget(bytes:)`, `trim(toFraction:)`). The limit scales the caps,
/// a release trims down to them, and once no tracked Home view has shown for ``idleDelay`` the caches go
/// to 0 on one ``MainDeadline`` one-shot, as Chrome drops a hidden tab's resources only after it stays hidden.
///
/// ```swift
/// let caches = MessagesLabMemoryConsumer(budgetBytes: budget.homeRenderBitmapBytes, registry: coordinator, idle: deadline)
/// caches.track(host.visibilityNode)  // each Home view the person can see
/// caches.track(sidebar: list)        // each Home conversation list
/// ```
@MainActor
public final class MessagesLabMemoryConsumer {
    /// Large (a screen of row bitmaps, its pictures and the screens around it), dropped by unlinking and
    /// freed off main, drawn again off main on the next miss: it shrinks at warning and empties at critical.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    public static let memoryConsumerName = "home-messageslab"

    /// How long no tracked Home view shows before the caches go to 0.
    public static let idleDelay: Duration = .seconds(60)

    /// The bytes all the caches keep together at the full limit.
    public let budgetBytes: Int
    /// The limit the coordinator gave last.
    public private(set) var limit = MemoryLimit.default
    /// No tracked Home view has shown for ``idleDelay``: the caches keep nothing until one shows.
    public private(set) var isIdle = false

    private let transcript: MessagesLabTranscriptCaches
    private var sidebars: [WeakSidebar] = []
    /// The tracked Home views' nodes: whether any of them is visible (a window's, a tab's or a page's).
    private let shown = ShownWindows()
    private var shownWatch: ShownWindowsObservation?
    private let idle: MainDeadline
    private var registration: MemoryConsumerRegistration?

    private struct WeakSidebar {
        weak var list: CmuxSidebarView?
    }

    /// Makes the consumer and registers it; it holds its registration for its life.
    ///
    /// - Parameters:
    ///   - budgetBytes: The bytes all the caches keep together at the full limit.
    ///   - registry: The memory coordinator.
    ///   - idle: The one-shot that empties the caches once no Home view shows (a background-class deadline).
    ///   - caches: The transcript caches (the process's own by default).
    public init(budgetBytes: Int, registry: any MemoryConsumerRegistry, idle: MainDeadline,
                caches: MessagesLabTranscriptCaches = MessagesLabTranscriptCaches()) {
        self.budgetBytes = max(0, budgetBytes)
        self.idle = idle
        transcript = caches
        applyBudget()
        shownWatch = shown.observe { [weak self] anyShown in self?.shownChanged(anyShown) }
        registration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
        shownChanged(shown.anyShown)
    }

    /// Counts `node` (a Home view's place in the visibility tree) as a Home view the person may see.
    /// Track a node under its window's node (`ViewVisibility`), so an occluded or miniaturized window and
    /// a hidden app count as not shown. Tracking a node again does nothing; a released node stops counting.
    ///
    /// - Parameter node: The view's node.
    public func track(_ node: VisibilityNode) {
        shown.track(node)
    }

    /// Sizes and trims `sidebar`'s row bitmaps with the others: the lists share a ninth of the budget
    /// (MessagesLab's 40 MB list beside its 304 MB of transcript caches).
    ///
    /// - Parameter sidebar: A Home conversation list.
    public func track(sidebar: HomeSidebarView) {
        sidebars.removeAll { $0.list == nil || $0.list === sidebar.list }
        sidebars.append(WeakSidebar(list: sidebar.list))
        applyBudget()
    }

    /// The bytes the caches may keep now: the budget scaled by the limit, 0 while idle.
    public var allowedBytes: Int {
        isIdle ? 0 : limit.scale(budgetBytes)
    }

    /// Bytes the caches hold now (pixels and the transcript's text measurements), read from their counters.
    public var memoryBytes: Int {
        liveSidebars.reduce(transcript.bytes) { $0 + $1.bitmapBytes }
    }

    private var liveSidebars: [CmuxSidebarView] { sidebars.compactMap(\.list) }

    private func shownChanged(_ anyShown: Bool) {
        if anyShown {
            idle.cancel()
            guard isIdle else { return }
            isIdle = false
            applyBudget()
        } else {
            idle.schedule(after: Self.idleDelay) { [weak self] in self?.idleOut() }
        }
    }

    private func idleOut() {
        guard !shown.anyShown, !isIdle else { return }
        isIdle = true
        applyBudget()
        trim(toFraction: 0)
    }

    /// Sets every cache's cap from ``allowedBytes``; frees nothing (each trims at its next store).
    private func applyBudget() {
        let allowed = allowedBytes
        let lists = liveSidebars
        let listShare = allowed / 9
        transcript.setBudget(bytes: allowed - listShare)
        for list in lists { list.setBitmapBudget(bytes: listShare / lists.count) }
    }

    private func trim(toFraction fraction: Double) {
        transcript.trim(toFraction: fraction)
        for list in liveSidebars { list.trimBitmaps(toFraction: fraction) }
    }
}

extension MessagesLabMemoryConsumer: MemoryConsumer {
    /// Scales the caches' caps from now on; frees nothing (the next store drops the oldest).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        self.limit = limit
        applyBudget()
    }

    /// Trims the least recently used bitmaps, pictures and tiles down to what the slice's limit allows, in
    /// one pass of dictionary unlinks; the images are freed off main (rows on screen keep what their layers show).
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        let held = memoryBytes, cap = allowedBytes
        if held > cap { trim(toFraction: Double(cap) / Double(held)) }
        return .done
    }

    /// What the caches hold now.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: memoryBytes,
                    entries: liveSidebars.reduce(transcript.entryCount) { $0 + $1.bitmapCount })
    }
}
