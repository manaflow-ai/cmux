package import CmuxNextCompat
package import CmuxNextSettings

/// Where each cmux page (agent chats, New Tab, Settings and the other WebUI pages) should be in its
/// lifecycle, and when to look again (p13-webui.md section 3.C). Pure: the page lifecycle controller
/// feeds it facts and a clock reading and performs the result; it reads no clock and knows no view.
///
/// A shown page is ``State/active``. A hidden page freezes once nothing in its keep reasons blocks a
/// freeze, and is discarded once nothing blocks a discard and it was hidden for
/// ``Timing/discardAfter(at:setting:)``. The keep reasons are Chrome's `CannotFreezeReason`
/// (components/performance_manager/public/freezing/cannot_freeze_reason.h: kVisible, kRecentlyVisible,
/// kAudible, kHoldingWebLock, capture, devices, kWebRTC, kLoading, kMostRecentlyUsed) plus the
/// `CannotDiscardReason`s of chrome/browser/performance_manager/policies/discard_eligibility_policy.cc
/// that apply to a page (kFormInteractions, kUserEdits) and cmux's own (an agent turn, a draft, a
/// shell command, a remote chat, the preload). Chrome never freezes WebUI (kWebUI); cmux does, for the
/// reasons in webui-DESIGN.md.
///
/// ```swift
/// let plan = PageLifecyclePlanner().plan(pages, conditions: .init(setting: setting, pressure: .normal, energySaver: false))
/// ```
package nonisolated struct PageLifecyclePlanner: Sendable {
    /// A page's lifecycle state, from most to least alive.
    package nonisolated enum State: String, Hashable, Sendable, CaseIterable {
        /// Shown: the engine draws it and every event reaches it.
        case active
        /// Hidden but running: the router holds its events, its timers are throttled.
        case hidden
        /// Hidden and frozen: no task, timer or frame runs; it keeps its memory.
        case frozen
        /// Its document is gone; the shell keeps its route, state and snapshot and loads it when shown.
        case discarded
    }

    /// Why a hidden page stays where it is. Raw values are the names `debug.discards` reports.
    package nonisolated enum KeepReason: String, Hashable, Sendable, CaseIterable {
        // Block freeze and discard.

        /// The page shows now (Chrome's kVisible).
        case visible
        /// Hidden less than ``Timing/visibleWindow(energySaver:)`` ago (Chrome's kRecentlyVisible).
        case recentlyVisible = "recently_visible"
        /// Still loading, until its load and first paint (Chrome's kLoading).
        case loading
        /// Web Inspector or DevTools is open on it.
        case inspector
        /// It holds the key focus of its window.
        case focused
        /// A file drop on it is still being read.
        case fileDrop = "file_drop"
        /// A popup or menu it opened is up.
        case popup
        /// A confirmation sheet it opened waits for an answer.
        case confirmation
        /// Dictation into it runs.
        case dictation
        /// It captures the camera, microphone or screen (Chrome's kCapturing*).
        case capture
        /// It plays sound (Chrome's kAudible).
        case audible
        /// A connected WebRTC peer connection (Chrome's kWebRTC).
        case webRTC = "web_rtc"
        /// An open USB, HID, serial or Bluetooth device (Chrome's kConnectedToUSB, kConnectedToBluetooth).
        case connectedDevice = "connected_device"
        /// It holds a Web Lock or an IndexedDB lock (Chrome's kHoldingWebLock, kHoldingIndexedDBLock).
        case webLock = "web_lock"
        /// Its chat's agent turn runs: acpmux cannot resync a frozen page's stream yet.
        case turnRunning = "turn_running"
        /// The acpmux turn watch is down, so no chat's turn is known: every chat counts as running.
        case turnsUnknown = "turns_unknown"

        // Block freeze only.

        /// The most recently hidden page (Chrome's kMostRecentlyUsed): the switch back is warm.
        /// Chrome keeps it from freezing only; a discard still takes it after its timeout.
        case mostRecentlyUsed = "most_recently_used"
        /// `browser.freezeHiddenTabs` is off: hidden pages keep running, and still discard on time.
        case freezeOff = "freeze_off"
        /// A host call waits for the page's answer, or a call thawed the page less than one recently visible
        /// window ago: a freeze would stall it (Chrome's freezing policy freezes a page only once no
        /// `CannotFreezeReason` holds, components/performance_manager/freezing/freezing_policy.cc). A discard
        /// still takes it on time, so a call that never answers keeps no page alive.
        case pageCall = "page_call"

        // Block discard only.

        /// The person edited its document (Chrome's kUserEdits).
        case userEdits = "user_edits"
        /// The person typed into its form fields (Chrome's kFormInteractions).
        case formInteraction = "form_interaction"
        /// Its `beforeunload` would ask before it unloads.
        case beforeUnload = "before_unload"
        /// Its chat holds an unsent draft or attachments.
        case draft
        /// Its tab is pinned and `browser.hibernatePinnedTabs` is off.
        case pinned
        /// A shell command ran in its chat: discarding ends the command or drops its output.
        case shellCommandRan = "shell_command_ran"
        /// Its chat's agent waits on the person.
        case awaitingPerson = "awaiting_person"
        /// Another machine's chat: this Mac cannot rebuild it.
        case remoteChat = "remote_chat"
        /// The one preloaded page document (the New Tab preload): the preload slot owns its life.
        case preload
        /// Nothing could rebuild it (an agent chat with no session yet).
        case unrestorable
        /// `browser.hibernation` is off, at every memory pressure.
        case hibernationOff = "hibernation_off"
        /// cmux.json does not set `browser.hibernation`: a discarded page reloads when it shows, so hidden
        /// pages only freeze, which keeps their state, and are never discarded on their own, at any memory
        /// pressure (`BrowserHibernationSetting.discardsAutomatically`, as ``HibernationPlanner`` keeps browser
        /// tabs as `keepsState`). The person's own discard is not the planner's and still applies.
        case discardsOff = "discards_off"

        /// The reason keeps a hidden page from freezing.
        package var blocksFreeze: Bool {
            switch self {
            case .visible, .recentlyVisible, .loading, .inspector, .focused, .fileDrop, .popup, .confirmation,
                 .dictation, .capture, .audible, .webRTC, .connectedDevice, .webLock, .turnRunning, .turnsUnknown,
                 .mostRecentlyUsed, .freezeOff, .pageCall:
                true
            case .userEdits, .formInteraction, .beforeUnload, .draft, .pinned, .shellCommandRan, .awaitingPerson,
                 .remoteChat, .preload, .unrestorable, .hibernationOff, .discardsOff:
                false
            }
        }

        /// The reason keeps a hidden page from being discarded.
        package var blocksDiscard: Bool { !Self.freezeOnly.contains(self) }

        /// The reasons that block a freeze and let a discard through.
        package static let freezeOnly: Set<KeepReason> = [.mostRecentlyUsed, .freezeOff, .pageCall]

        /// The reasons only the planner sets, from the page's facts and the conditions.
        package static let derived: Set<KeepReason> = [.visible, .recentlyVisible, .mostRecentlyUsed, .freezeOff, .hibernationOff,
                                                       .discardsOff]

        /// The reasons time alone ends; an event ends every other one.
        package static let timeBound: Set<KeepReason> = [.recentlyVisible]

        /// The ``derived`` reasons that come from the person's settings, not from time or the order of hides.
        package static let fromSettings: Set<KeepReason> = [.freezeOff, .hibernationOff, .discardsOff]

        /// The reason, appearing on a frozen page, thaws it: a freeze blocker the page, its owner or a setting
        /// set, as Chrome unfreezes a page that starts to play audio. The derived reasons of time and the order
        /// of hides (recently visible, most recently used) never thaw one.
        package var thawsFrozenPage: Bool {
            blocksFreeze && (!Self.derived.contains(self) || Self.fromSettings.contains(self))
        }

        /// `reasons` in declaration order, as ``Decision/keptBy`` reports them.
        package static func ordered(_ reasons: Set<KeepReason>) -> [KeepReason] {
            allCases.filter { reasons.contains($0) }
        }
    }

    /// One page, as the controller knows it.
    package nonisolated struct Page: Hashable, Sendable {
        package var key: String
        /// Its renderer group (`agent`, `privileged`, `viewer`, `solo`, `secrets`); passed through.
        package var group: String?
        /// The page draws in a window now.
        package var isShown: Bool
        /// Seconds since it was last shown; read only while hidden, discarded or not.
        package var hiddenFor: Double
        /// What the page and its owner say keeps it (page JS can only add reasons). The planner sets
        /// the ``KeepReason/derived`` reasons itself from the facts, ignoring them here, and drops
        /// ``KeepReason/pinned`` when pinned tabs hibernate.
        package var keepReasons: Set<KeepReason>
        /// Its document was discarded already; it stays so until shown.
        package var isDiscarded: Bool

        package init(key: String, group: String? = nil, isShown: Bool = false, hiddenFor: Double = 0,
                     keepReasons: Set<KeepReason> = [], isDiscarded: Bool = false) {
            self.key = key
            self.group = group
            self.isShown = isShown
            self.hiddenFor = hiddenFor
            self.keepReasons = keepReasons
            self.isDiscarded = isDiscarded
        }
    }

    /// The app-wide facts every page's plan depends on.
    package nonisolated struct Conditions: Hashable, Sendable {
        /// `browser.hibernation` and its companions. Pages take its switch, whether it was written
        /// (``KeepReason/discardsOff``: unwritten, hidden pages only freeze), its pinned rule, a number
        /// of minutes as the floor of their discard time (``Timing/discardAfter(at:setting:)``) and
        /// `browser.freezeHiddenTabs` "off" (``KeepReason/freezeOff``). The named modes' minutes and
        /// the freeze seconds time browser tabs; pages use ``Timing`` (p13-webui.md section 3.C).
        package var setting: BrowserHibernationSetting
        package var pressure: MemoryPressureLevel
        /// Pages spend less (`EnergyPolicy.pageSaver`): Energy Saver, or Low Power Mode while the
        /// `energySaver` feature is off.
        package var energySaver: Bool

        package init(setting: BrowserHibernationSetting = .fallback, pressure: MemoryPressureLevel = .normal,
                     energySaver: Bool = false) {
            self.setting = setting
            self.pressure = pressure
            self.energySaver = energySaver
        }
    }

    /// The planner's times, in seconds (p13-webui.md section 3.C).
    package nonisolated struct Timing: Hashable, Sendable {
        /// Hidden this long, a page is no longer recently visible and may freeze.
        package var recentlyVisible: Double = 10
        /// The same under Energy Saver, which, as for the neighbor tabs (`NeighborTabs.radius`), spends
        /// fewer wakeups on a quick switch back.
        package var saverRecentlyVisible: Double = 3
        /// Hidden this long without memory pressure, a page is discarded.
        package var discardAfterNormal: Double = 300
        /// At warning pressure.
        package var discardAfterWarning: Double = 60
        /// At critical pressure.
        package var discardAfterCritical: Double = 10
        /// No pressure discards a page hidden less than this, so a chat's last keystrokes reach acpmux.
        package var minimumHidden: Double = 10
        /// Discards per pass and pass interval without pressure: the browser's normal pace.
        package var normalPace = HibernationPlanner.normalPace
        /// Under pressure: Chrome's urgent pace, one discard every 5 s (`Pace.chromeUrgent`).
        package var urgentPace = HibernationPlanner.Pace.chromeUrgent

        package init() {}

        /// Seconds a hidden page counts as recently visible.
        package func visibleWindow(energySaver: Bool) -> Double {
            energySaver ? saverRecentlyVisible : recentlyVisible
        }

        /// Seconds hidden before a page is discarded at `pressure`, never under ``minimumHidden``, nor
        /// under the minutes the person wrote in `browser.hibernation`, at that pressure as for
        /// browser tabs (``HibernationPlanner/threshold(_:pressure:)``).
        package func discardAfter(at pressure: MemoryPressureLevel, setting: BrowserHibernationSetting) -> Double {
            let pageTime = switch pressure {
            case .normal: discardAfterNormal
            case .warning: discardAfterWarning
            case .critical: discardAfterCritical
            }
            let personTime: Double = switch setting.mode {
            case .minutes: HibernationPlanner.threshold(setting, pressure: pressure) ?? 0
            case .off, .moderate, .aggressive: 0
            }
            return max(pageTime, personTime, minimumHidden)
        }

        /// The discard pace at `pressure`.
        package func pace(at pressure: MemoryPressureLevel) -> HibernationPlanner.Pace {
            pressure == .normal ? normalPace : urgentPace
        }
    }

    /// One page's target state.
    package nonisolated struct Decision: Hashable, Sendable {
        package var key: String
        package var group: String?
        package var state: State
        /// Every reason that applies to the page, in ``KeepReason`` order; empty when discarded.
        package var keptBy: [KeepReason]
        /// Seconds until the page's state changes with time alone; nil when only an event changes it.
        package var nextDeadline: Double?

        package init(key: String, group: String?, state: State, keptBy: [KeepReason] = [], nextDeadline: Double? = nil) {
            self.key = key
            self.group = group
            self.state = state
            self.keptBy = keptBy
            self.nextDeadline = nextDeadline
        }
    }

    /// Every page's target state, the pages to discard now and when to look again.
    package nonisolated struct Plan: Hashable, Sendable {
        package var decisions: [String: Decision] = [:]
        /// Pages to discard in this pass, longest hidden first (at most the pace's `perPass`).
        package var discards: [String] = []
        /// Seconds until the earliest ``Decision/nextDeadline``; nil when no page changes with time.
        package var nextCheck: Double?

        package init() {}

        package func state(of key: String) -> State? { decisions[key]?.state }
    }

    package var timing: Timing

    package init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// The reasons that apply to `page`: its own and the ones the planner derives from the facts.
    package func keepReasons(of page: Page, conditions: Conditions, isMostRecentlyUsed: Bool) -> Set<KeepReason> {
        var reasons = page.keepReasons.subtracting(KeepReason.derived)
        if page.isShown {
            reasons.insert(.visible)
        } else if page.hiddenFor < timing.visibleWindow(energySaver: conditions.energySaver) {
            reasons.insert(.recentlyVisible)
        }
        if isMostRecentlyUsed { reasons.insert(.mostRecentlyUsed) }
        if conditions.setting.freezeSeconds == nil { reasons.insert(.freezeOff) }
        if !conditions.setting.isEnabled {
            reasons.insert(.hibernationOff)
        } else if !conditions.setting.discardsAutomatically {
            // No `browser.hibernation` written: freezes go on, no discard (trunk #25920).
            reasons.insert(.discardsOff)
        }
        if conditions.setting.includesPinnedTabs { reasons.remove(.pinned) }
        return reasons
    }

    /// Each page's target state and the next deadline. O(pages) plus the sort of the pages due for
    /// a discard.
    package func plan(_ pages: [Page], conditions: Conditions) -> Plan {
        let window = timing.visibleWindow(energySaver: conditions.energySaver)
        let discardAfter = timing.discardAfter(at: conditions.pressure, setting: conditions.setting)
        let pace = timing.pace(at: conditions.pressure)
        let discardDue = max(discardAfter, pace.minimumHidden)
        let mostRecent = Self.mostRecentlyHidden(pages)
        var plan = Plan()
        var due: [(page: Page, reasons: Set<KeepReason>)] = []
        for page in pages {
            if page.isShown {
                plan.decisions[page.key] = Decision(key: page.key, group: page.group, state: .active, keptBy: [.visible])
                continue
            }
            if page.isDiscarded {
                plan.decisions[page.key] = Decision(key: page.key, group: page.group, state: .discarded)
                continue
            }
            let reasons = keepReasons(of: page, conditions: conditions, isMostRecentlyUsed: page.key == mostRecent)
            let freezeBlockers = reasons.filter(\.blocksFreeze)
            let discardBlockers = reasons.filter(\.blocksDiscard)
            let freezeIn = freezeBlockers.isSubset(of: KeepReason.timeBound) ? window - page.hiddenFor : nil
            let discardIn = discardBlockers.isSubset(of: KeepReason.timeBound) ? max(discardDue, window) - page.hiddenFor : nil
            if discardBlockers.isEmpty, let discardIn, discardIn <= 0 {
                due.append((page, reasons))
                continue
            }
            let state: State = freezeBlockers.isEmpty ? .frozen : .hidden
            let deadline = [state == .hidden ? freezeIn : nil, discardIn].compactMap { $0 }.filter { $0 > 0 }.min()
            plan.decisions[page.key] = Decision(key: page.key, group: page.group, state: state,
                                                keptBy: KeepReason.ordered(reasons), nextDeadline: deadline)
        }
        // Chrome's page_discarding_helper.cc order, the urgent pass's too: the longest hidden goes first.
        due.sort { UrgentDiscardRanker.longestHiddenFirst($0.page.hiddenFor, $0.page.key, $1.page.hiddenFor, $1.page.key) }
        for (index, entry) in due.enumerated() {
            let (page, reasons) = (entry.page, entry.reasons)
            if index < pace.perPass {
                plan.discards.append(page.key)
                plan.decisions[page.key] = Decision(key: page.key, group: page.group, state: .discarded)
            } else {
                // Due, but past this pass's share: it goes on a later pass, as far along as its reasons let it.
                let state: State = reasons.contains(where: \.blocksFreeze) ? .hidden : .frozen
                plan.decisions[page.key] = Decision(key: page.key, group: page.group, state: state,
                                                    keptBy: KeepReason.ordered(reasons), nextDeadline: pace.interval)
            }
        }
        plan.nextCheck = plan.decisions.values.compactMap(\.nextDeadline).min()
        return plan
    }

    /// The hidden pages the critical event's one urgent pass may take (``UrgentDiscardRanker``): live
    /// (not discarded), hidden at least ``Timing/minimumHidden``, and no reason blocks their discard
    /// (the most recently used role blocks a freeze only). Their timeout plays no part: under critical
    /// pressure the ranker, not the clock, picks which goes. With hibernation off or no `browser.hibernation`
    /// written (``KeepReason/hibernationOff``, ``KeepReason/discardsOff``) there is none, as
    /// ``HibernationPlanner/urgentCandidates(_:candidates:)`` has no browser tab then. O(pages).
    package func urgentCandidates(_ pages: [Page], conditions: Conditions) -> [UrgentDiscardRanker.Candidate] {
        let mostRecent = Self.mostRecentlyHidden(pages)
        return pages.compactMap { page in
            guard !page.isShown, !page.isDiscarded, page.hiddenFor >= timing.minimumHidden else { return nil }
            let reasons = keepReasons(of: page, conditions: conditions, isMostRecentlyUsed: page.key == mostRecent)
            guard !reasons.contains(where: \.blocksDiscard) else { return nil }
            return UrgentDiscardRanker.Candidate(key: page.key, kind: page.group == "agent" ? .agentPage : .internalPage,
                                                 hiddenFor: page.hiddenFor)
        }
    }

    /// The most recently hidden page's key. Discarded pages count, as Chrome's discarded tab keeps its
    /// PageNode and last-visible time: discarding the most recently hidden page never hands the role to
    /// an older, frozen page.
    private static func mostRecentlyHidden(_ pages: [Page]) -> String? {
        pages.filter { !$0.isShown }.min { ($0.hiddenFor, $0.key) < ($1.hiddenFor, $1.key) }?.key
    }
}
