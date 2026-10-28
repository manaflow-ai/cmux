package import CmuxNextCompat

/// Which page the app's one preload slot (`PagePreloadSlot`) should load ahead, and when
/// (plans/cmux-next/chrome-parity/p13-webui.md section 3.D). Pure: the slot's adapter feeds it facts
/// and a clock reading and performs the result; it reads no clock and knows no view.
///
/// Chrome's rules (chrome/browser/ui/webui/top_chrome/webui_contents_preload_manager.h):
/// - At most one page is preloaded across the app ("At anytime, at most one WebContents is preloaded
///   across all profiles"). A decision names one page or none, and a held preload is never replaced:
///   only its claim or a drop empties the slot, so two pages never take turns evicting each other.
/// - No preload under memory pressure: warning or critical drops the held page and starts none.
/// - `MaybePreloadForBrowserContextLater` waits for the first non-empty paint or a 3 s deadline. cmux
///   then also waits for ``Timing/quietInput`` without input, so making a page never lands in the
///   person's typing.
///
/// New Tab is the default page; Settings, History or Cloud take its place for a while after the
/// person opened one (``Timing/recentOpen``) and closed it again.
///
/// ```swift
/// switch PreloadSelector().decide(.init(now: now, startedAt: launch, firstPaintAt: paint, lastInputAt: key,
///                                      pressure: pressure, lastOpened: opens, openNow: shown, held: slot.page)) {
/// case .preload(let page): slot.preload(page.rawValue)
/// case .later(let until, let orFirstPaint): deadline.arm(at: until, alsoOnFirstPaint: orFirstPaint)
/// case .drop: slot.drop()
/// case .keep, .blocked: break
/// }
/// ```
package nonisolated struct PreloadSelector: Sendable {
    /// A page the slot can preload. Raw values are the slot's keys (`PagePreloadSlot.Key`).
    package nonisolated enum Page: String, Hashable, Sendable, CaseIterable {
        case newTab
        case settings
        case history
        case cloud

        /// A page the app shows at most once at a time: preloading it while it is open is waste.
        package var isSingleton: Bool { self != .newTab }
    }

    /// The selector's times, in seconds.
    package nonisolated struct Timing: Hashable, Sendable {
        /// No first paint this long after the start, the preload stops waiting for one (Chrome's 3 s
        /// deadline in `MaybePreloadForBrowserContextLater`).
        package var firstPaintDeadline: Double = 3
        /// After the first paint or its deadline, input must be quiet this long before a preload starts.
        package var quietInput: Double = 0.75
        /// A Settings, History or Cloud open this recent makes that page the preload instead of New Tab.
        package var recentOpen: Double = 600

        package init() {}
    }

    /// What the selector reads; every time is in seconds on one monotonic clock.
    package nonisolated struct Facts: Hashable, Sendable {
        /// The clock reading the decision is for.
        package var now: Double
        /// When the app started; the first-paint deadline counts from here.
        package var startedAt: Double
        /// The app's first non-empty paint; nil before it.
        package var firstPaintAt: Double?
        /// The person's last key, click or scroll; nil before any.
        package var lastInputAt: Double?
        package var pressure: MemoryPressureLevel
        /// When each page was last opened by the person; a page never opened has no entry.
        package var lastOpened: [Page: Double]
        /// The pages open in a tab or window now.
        package var openNow: Set<Page>
        /// The page the slot holds; nil when it is empty.
        package var held: Page?

        package init(now: Double, startedAt: Double = 0, firstPaintAt: Double? = nil, lastInputAt: Double? = nil,
                     pressure: MemoryPressureLevel = .normal, lastOpened: [Page: Double] = [:],
                     openNow: Set<Page> = [], held: Page? = nil) {
            self.now = now
            self.startedAt = startedAt
            self.firstPaintAt = firstPaintAt
            self.lastInputAt = lastInputAt
            self.pressure = pressure
            self.lastOpened = lastOpened
            self.openNow = openNow
            self.held = held
        }
    }

    /// What the slot should do now. Each case starts at most one preload.
    package nonisolated enum Decision: Hashable, Sendable {
        /// The slot is empty and may fill: load this page.
        case preload(Page)
        /// Too early (no first paint and before its deadline) or input is not quiet yet: decide again at
        /// `at` with the facts of then, and also on the first paint when `orFirstPaint` is true. That is
        /// set while no paint has come and the deadline is ahead, so `at` is only the deadline's bound:
        /// the paint can open the gate sooner (Chrome starts on the paint or the deadline, whichever
        /// comes first).
        case later(at: Double, orFirstPaint: Bool)
        /// The slot holds a page and keeps it.
        case keep
        /// Memory pressure: close the held page; none starts until pressure is normal again.
        case drop
        /// Memory pressure and an empty slot: nothing to do until pressure is normal again.
        case blocked
    }

    package var timing: Timing

    package init(timing: Timing = .init()) {
        self.timing = timing
    }

    /// The slot's next step for `facts`.
    package func decide(_ facts: Facts) -> Decision {
        guard facts.pressure == .normal else { return facts.held == nil ? .blocked : .drop }
        if facts.held != nil { return .keep }
        let ready = earliestStart(facts)
        guard facts.now >= ready else {
            let paintCanComeFirst = facts.firstPaintAt == nil && facts.now < facts.startedAt + timing.firstPaintDeadline
            return .later(at: ready, orFirstPaint: paintCanComeFirst)
        }
        return .preload(page(for: facts))
    }

    /// The first moment a preload may start: the first paint or its deadline, whichever comes first,
    /// then ``Timing/quietInput`` after that moment or after the last input, whichever is later.
    package func earliestStart(_ facts: Facts) -> Double {
        let deadline = facts.startedAt + timing.firstPaintDeadline
        let gate = facts.firstPaintAt.map { min($0, deadline) } ?? deadline
        return max(gate, facts.lastInputAt ?? gate) + timing.quietInput
    }

    /// The page to preload: the most recently opened of Settings, History and Cloud when that open is
    /// within ``Timing/recentOpen`` and the page is not open now; New Tab otherwise. Equal open times
    /// fall to the greater raw value, so the choice never follows the dictionary's per-process order.
    package func page(for facts: Facts) -> Page {
        let recent = facts.lastOpened
            .filter { page, openedAt in
                page.isSingleton && !facts.openNow.contains(page) && facts.now - openedAt <= timing.recentOpen
            }
            .max { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) }
        return recent?.key ?? .newTab
    }
}
