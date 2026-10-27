package import CmuxNextCompat

/// The app's one discard path of sidebar sections (`ContentKind.sidebarSection`, p07-memory.md 3.C, task 100): the
/// right sidebar's sections and the docked Home's two views, each made once per window. Each owner's
/// ``SidebarSectionRelease`` reports here, and the same ``ContentDiscardScheduler`` every other kind goes through
/// says when a hidden one goes: ``releaseAfter`` hidden as the Memory Saver mode scales it (Chrome's
/// proactive_discarding_policy.cc), or on the urgent pace at critical pressure (urgent_page_discarding_policy.cc).
/// The owner saves its view-state record first, so the next show builds the section as it was left.
@MainActor
package final class SidebarSectionDiscards {
    /// Ten minutes hidden, at the Memory Saver mode's medium.
    package static let defaultReleaseAfter: Duration = .seconds(600)

    package let scheduler: ContentDiscardScheduler
    /// How long a hidden section is kept at the Memory Saver mode's medium and normal pressure.
    package let releaseAfter: Duration
    /// The sections the planner heard from, by key; one whose owner went is dropped at the next new key.
    private var sections: [String: Entry] = [:]

    private struct Entry {
        weak var section: SidebarSectionRelease?
    }

    /// - Parameters:
    ///   - scheduler: A ``ContentKind/sidebarSection`` scheduler; this planner becomes its host.
    ///   - releaseAfter: How long a hidden section is kept.
    package init(scheduler: ContentDiscardScheduler, releaseAfter: Duration = SidebarSectionDiscards.defaultReleaseAfter) {
        self.scheduler = scheduler
        self.releaseAfter = releaseAfter
        scheduler.host = self
    }

    /// The app's planner: on the memory coordinator, each release counted by `recordDiscard`.
    package convenience init(memory: any MemoryConsumerRegistry, recordDiscard: @escaping () -> Void) {
        self.init(scheduler: ContentDiscardScheduler(kind: .sidebarSection, memory: memory))
        scheduler.onDiscard = recordDiscard
    }

    private func section(_ key: String) -> SidebarSectionRelease? { sections[key]?.section }

    private func track(_ section: SidebarSectionRelease) {
        let key = section.key
        guard sections[key]?.section !== section else { return }
        sections = sections.filter { $0.value.section != nil }
        sections[key] = Entry(section: section)
    }
}

extension SidebarSectionDiscards: SidebarSectionPlanner {
    package func sectionDidHide(_ section: SidebarSectionRelease) {
        track(section)
        scheduler.contentDidHide(section.key)
    }

    package func sectionDidShow(_ section: SidebarSectionRelease) {
        track(section)
        scheduler.contentDidShow(section.key)
    }

    /// The scheduler forgets it as it does a shown key: not due, its preparation stopped.
    package func sectionDidEnd(_ section: SidebarSectionRelease) {
        scheduler.contentDidShow(section.key)
        sections[section.key] = nil
    }
}

extension SidebarSectionDiscards: ContentDiscardHost {
    /// Its release time while it is held and hidden; nil once it showed, went or its owner did.
    package func discardPolicy(of key: String) -> ContentDiscardPolicy? {
        guard let section = section(key), section.isHolding, !section.isShown else { return nil }
        return .afterHidden(releaseAfter)
    }

    package func keepReasons(of key: String) -> [CannotDiscardReason] { [] }

    package func isDrawn(_ key: String) -> Bool { false }

    /// The owner saves its view-state record; the record stays with the owner, which makes the section again.
    package func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard let section = section(key), await section.prepare() else { return nil }
        return ContentViewState()
    }

    package func commitDiscard(_ key: String) {
        if section(key)?.releaseNow() == true { scheduler.noteDiscarded(key) }
    }
}
