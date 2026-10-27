package import CmuxNextCompat

/// The app's one discard path of overlay pages (`ContentKind.overlayPage`, p07-memory.md 3.C, task 086): the icon
/// picker's page, the update card's highlights, each Extensions bubble's rows and the made-ahead file picker. Each
/// owner's ``OverlayPageRelease`` reports here, and the same ``ContentDiscardScheduler`` every other kind goes
/// through says when hidden content goes: its ``OverlayPageRelease/releaseAfter`` hidden as the Memory Saver mode
/// scales it (Chrome's proactive_discarding_policy.cc), or on the urgent pace from warning pressure on, since nothing
/// a person made lives in it (urgent_page_discarding_policy.cc). The scheduler's exemptions say why one stays, and
/// each release counts in the memory histograms (the App's `MemoryHistograms.discardKinds(overlayPages:)`).
@MainActor
package final class OverlayPageDiscards {
    package let scheduler: ContentDiscardScheduler
    /// The releases the planner heard from, by key; an owner that went is dropped at the next new key.
    private var pages: [String: Entry] = [:]

    private struct Entry {
        weak var page: OverlayPageRelease?
    }

    /// - Parameter scheduler: An ``ContentKind/overlayPage`` scheduler; this planner becomes its host.
    package init(scheduler: ContentDiscardScheduler) {
        self.scheduler = scheduler
        scheduler.host = self
    }

    /// The app's planner: on the memory coordinator, each release counted by `recordDiscard`.
    package convenience init(memory: any MemoryConsumerRegistry, recordDiscard: @escaping () -> Void) {
        self.init(scheduler: ContentDiscardScheduler(kind: .overlayPage, memory: memory, urgentAtWarning: true))
        scheduler.onDiscard = recordDiscard
    }

    /// The terms the composition root hands each owner: `releaseAfter` hidden at the Memory Saver mode's medium.
    package func terms(releaseAfter: Duration) -> OverlayPageReleaseTerms {
        OverlayPageReleaseTerms(releaseAfter: releaseAfter, planner: self)
    }

    private func page(_ key: String) -> OverlayPageRelease? { pages[key]?.page }

    private func track(_ page: OverlayPageRelease) {
        let key = page.key
        guard pages[key]?.page !== page else { return }
        pages = pages.filter { $0.value.page != nil }
        pages[key] = Entry(page: page)
    }
}

extension OverlayPageDiscards: OverlayPagePlanner {
    package func overlayPageDidHide(_ page: OverlayPageRelease) {
        track(page)
        scheduler.contentDidHide(page.key)
    }

    package func overlayPageDidShow(_ page: OverlayPageRelease) {
        track(page)
        scheduler.contentDidShow(page.key)
    }

    /// The scheduler forgets it as it does a shown key: not due, its preparation stopped.
    package func overlayPageDidEnd(_ page: OverlayPageRelease) {
        scheduler.contentDidShow(page.key)
        pages[page.key] = nil
    }
}

extension OverlayPageDiscards: ContentDiscardHost {
    /// Its release time while it is held and hidden; nil once it showed, went or its owner did.
    package func discardPolicy(of key: String) -> ContentDiscardPolicy? {
        guard let page = page(key), page.isHolding, !page.isShown else { return nil }
        return .afterHidden(page.releaseAfter)
    }

    /// A closing fade or a sheet still shows it: kept, and looked at again one release time later.
    package func keepReasons(of key: String) -> [CannotDiscardReason] {
        page(key)?.isInUse == true ? [.visible] : []
    }

    package func isDrawn(_ key: String) -> Bool { false }

    /// Nothing to save: an overlay page is made fresh for its next open.
    package func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard discardPolicy(of: key) != nil, keepReasons(of: key).isEmpty else { return nil }
        return ContentViewState()
    }

    package func commitDiscard(_ key: String) {
        if page(key)?.releaseNow() == true { scheduler.noteDiscarded(key) } else { scheduler.noteDiscardFailed(key) }
    }
}
