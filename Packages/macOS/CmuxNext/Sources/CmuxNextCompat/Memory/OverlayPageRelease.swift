/// The app's one discard planner of overlay pages (`ContentKind.overlayPage`, p07-memory.md section 3.C): each
/// ``OverlayPageRelease`` reports its shows and hides here, and the planner calls ``OverlayPageRelease/releaseNow()``
/// when hidden content is due. `OverlayPageDiscards` (CmuxNextHibernation) is the one conformer, over the
/// `ContentDiscardScheduler` every other kind of content goes through.
@MainActor
public protocol OverlayPagePlanner: AnyObject {
    /// `page`'s content exists and does not show (made ahead, or its open ended): its hidden time starts now.
    func overlayPageDidHide(_ page: OverlayPageRelease)
    /// `page`'s content shows: it is not due.
    func overlayPageDidShow(_ page: OverlayPageRelease)
    /// `page`'s owner went, or dropped the content itself: the planner forgets it.
    func overlayPageDidEnd(_ page: OverlayPageRelease)
}

/// One owner's side of an overlay or made-ahead page (`ContentKind.overlayPage`, task 086): the icon picker's page,
/// the update card's highlights page, a pane's Extensions bubble rows, the made-ahead file picker. Such content is
/// made for one person's open and kept so the next open is warm; nothing a person made lives in it.
///
/// It decides nothing on its own: the owner reports ``didMake()``, ``didShow()`` and ``didHide()``, and the app's
/// one planner (``OverlayPagePlanner``) says when hidden content goes: after ``releaseAfter`` hidden as the Memory
/// Saver mode scales it, or on Chrome's urgent pace from warning pressure on
/// (chrome/browser/performance_manager/policies/urgent_page_discarding_policy.cc). Chrome makes its dialogs per
/// request and ends them with it (ui/shell_dialogs/select_file_dialog_mac.mm); ``allowsPrewarm`` is false until the
/// first show since the last release, so a launch's idle warm-up makes none for a person who never opens it.
///
/// ```swift
/// release = terms.release(owner: "iconPicker", inUse: { [weak self] in self?.isOpen ?? false }) { [weak self] in
///     self?.dropWarm()
/// }
/// ```
@MainActor
public final class OverlayPageRelease {
    /// Five minutes hidden (p07-memory.md section 3.E), at the Memory Saver mode's medium.
    public nonisolated static let defaultReleaseAfter: Duration = .seconds(300)

    /// What the content is (`iconPicker`, `extensionsMenu`), the start of its ``key``.
    public let owner: String
    /// How long hidden content is kept, at the Memory Saver mode's medium and normal pressure.
    public let releaseAfter: Duration
    /// Whether the content exists now.
    public private(set) var isHolding = false
    /// Whether the content shows now.
    public private(set) var isShown = false
    /// Whether it showed since it was made or last released.
    public private(set) var usedSinceRelease = false
    /// The releases done so far.
    public private(set) var releases = 0

    private let planner: any OverlayPagePlanner
    private let inUse: @MainActor () -> Bool
    private let drop: @MainActor () -> Void

    /// - Parameters:
    ///   - owner: What the content is.
    ///   - releaseAfter: How long hidden content is kept at the Memory Saver mode's medium.
    ///   - planner: The App's one overlay page planner.
    ///   - inUse: Whether hidden content is still in use (a closing fade, a sheet that shows it), so it stays.
    ///   - drop: Drops the content; called only while ``inUse`` is false.
    public init(owner: String, releaseAfter: Duration = OverlayPageRelease.defaultReleaseAfter, planner: any OverlayPagePlanner,
                inUse: @escaping @MainActor () -> Bool, drop: @escaping @MainActor () -> Void) {
        self.owner = owner
        self.releaseAfter = releaseAfter
        self.planner = planner
        self.inUse = inUse
        self.drop = drop
    }

    /// The planner's name for this content: its owner and its identity, unique while it lives.
    public var key: String { "\(owner)#\(UInt(bitPattern: ObjectIdentifier(self).hashValue))" }

    /// Whether an idle warm-up may make the content now: only after a show since the last release.
    public var allowsPrewarm: Bool { usedSinceRelease }

    /// Whether held, hidden content is still in use, so a release now would take it from the person.
    public var isInUse: Bool { inUse() }

    /// The content was made; hidden content starts its hidden time now. A rebuild of held content (a prepare
    /// after new extensions) keeps the hidden time it had.
    public func didMake() {
        guard !isHolding else { return }
        isHolding = true
        if !isShown { planner.overlayPageDidHide(self) }
    }

    /// The content shows (an open): it is not due.
    public func didShow() {
        usedSinceRelease = true
        isShown = true
        planner.overlayPageDidShow(self)
    }

    /// The content stopped showing (a close): its hidden time starts.
    public func didHide() {
        guard isShown else { return }
        isShown = false
        if isHolding { planner.overlayPageDidHide(self) }
    }

    /// The planner's call: drops held, hidden content that is not in use. False, and nothing goes, otherwise.
    @discardableResult
    public func releaseNow() -> Bool {
        guard isHolding, !isShown, !inUse() else { return false }
        drop()
        isHolding = false
        usedSinceRelease = false
        releases += 1
        return true
    }

    /// The owner goes (or dropped the content itself): the planner forgets it.
    public func cancel() {
        isHolding = false
        planner.overlayPageDidEnd(self)
    }
}
