public import CmuxNextCompat
public import CmuxNextWakeups

/// When an overlay or made-ahead page goes (`ContentKind.overlayPage`, p07-memory.md section 3.C, task 086): the
/// icon picker's page, the update card's highlights page, a pane's Extensions bubble rows, the made-ahead file
/// picker. Such content is made for one person's open and kept so the next open is warm; nothing a person made
/// lives in it.
///
/// - It is released ``releaseAfter`` after it last hid, on one background ``MainDeadline`` (one-shot: each show
///   cancels it, each hide arms it again), as Chrome makes its dialogs per request and ends them with the request
///   (ui/shell_dialogs/select_file_dialog_mac.mm).
/// - At warning or critical memory pressure a hidden one is released on the deadline's next fire, not in the turn of
///   the level change: a lossy consumer whose recreation is expensive (a page load), Chrome's urgent discard traits
///   (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc).
/// - ``allowsPrewarm`` is false until the first show since the last release, so a launch's idle warm-up makes none
///   for a person who never opens it.
///
/// The owner reports ``didMake()``, ``didShow()`` and ``didHide()`` and does the release in `release`, which answers
/// false while the content is still in use (a closing fade, a sheet showing it): the deadline then looks again
/// ``busyRecheck`` later under pressure, ``releaseAfter`` later otherwise.
///
/// ```swift
/// release = OverlayPageRelease(owner: "iconPicker", deadline: MainDeadline(owner: "iconPicker.release",
///                              workClass: .background, scheduler: deadlines), memory: coordinator) { [weak self] in
///     self?.releaseWarm() ?? true
/// }
/// ```
@MainActor
public final class OverlayPageRelease {
    /// Five minutes after the last hide (p07-memory.md section 3.E).
    public static let defaultReleaseAfter: Duration = .seconds(300)
    /// How soon content still in use under memory pressure is looked at again.
    public static let busyRecheck: Duration = .seconds(1)

    /// One overlay page: a page or panel of one to 50 MB, nothing read or written to drop it, its state (the open's
    /// scroll, the bubble's highlight) lost and rebuilt by a page load.
    public nonisolated static let traits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossy, recreateCost: .expensive,
        releaseCPUCost: .low, isStateful: false, supportsMemoryLimit: false)

    /// What the content is (`iconPicker`, `extensionsMenu`), in the deadline's and the memory report's names.
    public let owner: String
    /// How long hidden content is kept at normal pressure.
    public let releaseAfter: Duration
    /// Whether the content exists now.
    public private(set) var isHolding = false
    /// Whether the content shows now.
    public private(set) var isShown = false
    /// Whether it showed since the store was made or last released it.
    public private(set) var usedSinceRelease = false
    /// The releases done so far.
    public private(set) var releases = 0
    /// The level the memory coordinator acts on; normal until its registration hands one.
    public private(set) var level: MemoryPressureLevel = .normal

    private let deadline: MainDeadline
    private let release: @MainActor () -> Bool
    private var registration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - owner: What the content is, for the report.
    ///   - releaseAfter: How long hidden content is kept at normal pressure.
    ///   - deadline: A background deadline on the app's one placer (`AppServices.mainDeadlines`).
    ///   - memory: The app's memory coordinator; nil releases on the deadline only.
    ///   - release: Drops the content; false while it is still in use, so it stays.
    public init(owner: String, releaseAfter: Duration = OverlayPageRelease.defaultReleaseAfter, deadline: MainDeadline,
                memory: (any MemoryConsumerRegistry)?, release: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.releaseAfter = releaseAfter
        self.deadline = deadline
        self.release = release
        registration = memory.map { MemoryConsumerRegistration(name: "overlay-page-\(owner)", traits: Self.traits, consumer: self, registry: $0) }
    }

    /// Whether an idle warm-up may make the content now: only after a show since the last release.
    public var allowsPrewarm: Bool { usedSinceRelease }

    /// Whether the release deadline is armed.
    public var isReleasePending: Bool { deadline.isScheduled }

    /// The content was made; hidden content starts its release time now.
    public func didMake() {
        isHolding = true
        if !isShown { arm() }
    }

    /// The content shows (an open): its release is called off.
    public func didShow() {
        usedSinceRelease = true
        isShown = true
        deadline.cancel()
    }

    /// The content stopped showing (a close): its release time starts.
    public func didHide() {
        guard isShown else { return }
        isShown = false
        arm()
    }

    /// Ends the memory coordinator's calls (the owner goes).
    public func cancel() {
        deadline.cancel()
        registration?.cancel()
        registration = nil
    }

    private func arm() {
        guard isHolding, !isShown else { return }
        deadline.schedule(after: level == .normal ? releaseAfter : .zero) { [weak self] in self?.releaseDue() }
    }

    private func releaseDue() {
        guard isHolding, !isShown else { return }
        guard release() else {
            deadline.schedule(after: level == .normal ? releaseAfter : Self.busyRecheck) { [weak self] in self?.releaseDue() }
            return
        }
        isHolding = false
        usedSinceRelease = false
        releases += 1
    }
}

extension OverlayPageRelease: MemoryLevelConsumer {
    /// Pressure releases hidden content at the deadline's next fire; back at normal the next hide waits again.
    public func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        guard level != self.level else { return }
        self.level = level
        if level != .normal { arm() }
    }

    public func updateMemoryLimit(_ limit: MemoryLimit) {}

    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { arm() }
        return .done
    }

    public var memoryUsage: MemoryUsage? { nil }
}
