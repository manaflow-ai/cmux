import CmuxNextCompat

/// New Terminal Tab's creations of one window's key hold (`CreationInputBuffer.open(…, newTerminal: true)`).
///
/// The person presses Ctrl-` and types a line for the new terminal while its create waits. Those keys are that
/// terminal's alone. Before this, the creation had no lane: at its reply each key ran again as typed in what had the
/// keyboard then. When the daemon refused the tab, that was the terminal the person pressed Ctrl-` in, and its shell
/// ran a line typed for another terminal (NewTerminalTabRefusedKeysTests).
///
/// - With a stand-in tab, the focus names the stand-in while the person types: its tab is the creation's lane.
/// - With no stand-in (a daemon from before `terminal-placement-env-v1`), the focus names the terminal of the press
///   until the reply: a key typed while the person did nothing since the press is the creation's (``ticket(newest:over:)``).
/// - Made: the keys are the daemon tab's of the new terminal (``tab(_:)``). The stand-in's id names no tab after the swap.
///   The hold waits for the store to list that tab while it holds such a key, at most its limit
///   (`CreationInputBuffer.awaitsMadeTerminal`), and the store's change wakes it (`holdsForMadeTab(wake:)`). It waits with
///   a stand-in too: when the reply settles the create at once, the stand-in leaves the pane before the hold gives its
///   keys out, and the keys sent into its view then were lost (NewTerminalTabRefusedKeysTests, afterTheStoreAppliedEachLine).
/// - Made, and no tab at the hold's limit: with a stand-in whose view sends by the terminal's id (a local daemon with
///   `terminal-input-while-creating-v1`) the keys go into that view. With no stand-in, or with one whose view cannot send
///   before its terminal exists (``silentStandIns``), they are lost, and no terminal gets them (``waitsForTab(_:standIn:)``).
/// - Refused: the keys go with the creation, into no terminal (``resolve(_:landed:madeTab:)``).
/// - Past the reply bound the keys run as typed, as every creation's do (cmux-ad m12): the creation is off this list.
@MainActor
struct NewTerminalKeys {
    /// The tickets, until one is refused, closed by the person or past the reply bound.
    var tickets: Set<Int> = []
    /// The tickets whose stand-in's view sends no key before its terminal exists (a daemon that does not queue such input:
    /// another machine's): a key typed into that view is dropped with it when the daemon's tab takes its place.
    var silentStandIns: Set<Int> = []
    /// What names the daemon's tab of each made terminal: nil until the store lists that tab.
    private var made: [Int: @MainActor () -> String?] = [:]
    /// The hold's one wait for the store to list a made terminal's tab (`CreationInputBuffer.holdsForMadeTab(wake:)`).
    var tabWatch: Task<Void, Never>?

    /// The ticket a key typed now is for, when the person did nothing since they asked for the hold's newest creation
    /// `newest`: that creation when it is a New Terminal Tab. `own`: the lane of the tab the focus names; a close that
    /// reads after it (a greater ticket) keeps its key.
    func ticket(newest: Int, over own: Int?) -> Int? {
        tickets.contains(newest) && (own ?? 0) <= newest ? newest : nil
    }

    /// The creation behind `ticket` got its reply. True for a New Terminal Tab the daemon refused: its keys go with it.
    mutating func resolve(_ ticket: Int, landed: Bool, madeTab: (@MainActor () -> String?)?) -> Bool {
        guard tickets.contains(ticket) else { return false }
        if landed { made[ticket] = madeTab } else { tickets.remove(ticket) }
        return !landed
    }

    /// The daemon's tab of the terminal the creation behind `ticket` made, once the store lists it.
    func tab(_ ticket: Int) -> String? { made[ticket].flatMap { $0() } }

    /// The creation behind `ticket` made a terminal that the store lists no tab of.
    func lost(_ ticket: Int) -> Bool { made[ticket].map { $0() == nil } ?? false }

    /// The keys of `ticket` (`standIn`: it has a stand-in's lane) have no terminal to go to until the store lists the made
    /// terminal's tab: no stand-in, or one whose view cannot send them. At the hold's end with no tab (its limit, or the
    /// focus left the content) they are counted and never typed, as a stranded workspace's (the terminal of the press is
    /// not theirs). With a stand-in that sends, they go into its view then.
    func waitsForTab(_ ticket: Int, standIn: Bool) -> Bool { (!standIn || silentStandIns.contains(ticket)) && lost(ticket) }
}

extension CreationInputBuffer {
    /// Whether the hold waits for the store to list a made terminal's tab (``awaitsMadeTerminal``). When it does, this
    /// arms the hold's one wake-up: `wake` runs one time, in a main-actor turn of its own, when a change of the store
    /// ends that wait. The wake-up is the store's change alone (an observation of what the made terminals' tab reads
    /// read): no poll and no timer, and the hold's limit stays its only bound. One observation for each hold, armed
    /// from the flush's gate only, and cancelled when the hold gives its keys out (``endMadeTabWatch()``).
    public func holdsForMadeTab(wake: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard awaitsMadeTerminal else { return false }
        guard newTerminals.tabWatch == nil else { return true }
        // task-owner: this hold's one wait for a made terminal's tab; `endMadeTabWatch()` cancels it when the hold gives its
        // keys out. Detached: the flush it wakes runs in a turn of its own, never under the arming run's task locals (as the
        // hold's bounds, review of #35874); high: the person's held keys wait for it.
        newTerminals.tabWatch = Task.detached(priority: .high) { [weak self] in
            await CreationInputBuffer.firstNo { [weak self] in self?.awaitsMadeTerminal ?? false }
            await self?.madeTabWatchEnded(wake)
        }
        return true
    }

    /// Returns when `waits` first answers no: at once, or after a change of what it read (an observation: no poll and no
    /// timer). It also returns when its task is cancelled.
    private static func firstNo(_ waits: @escaping @MainActor @Sendable () -> Bool) async {
        for await answer in ObservationStream(waits) where !answer { return }
    }

    /// The wait for the made terminal's tab ended: the wake-up runs, unless the hold gave its keys out first.
    private func madeTabWatchEnded(_ wake: @MainActor @Sendable () -> Void) {
        guard !Task.isCancelled else { return }
        newTerminals.tabWatch = nil
        wake()
    }

    /// The hold gives its keys out (its end, its limit or its window's close with it): it waits for no tab any more.
    func endMadeTabWatch() {
        newTerminals.tabWatch?.cancel()
        newTerminals.tabWatch = nil
    }

    /// Whether the hold's wake-up for a made terminal's tab is armed.
    var watchesMadeTab: Bool { newTerminals.tabWatch != nil }

    /// The creation whose keys alone keep waiting (``leftWorkspaceWithKeys``) while the window shows `shown` and its
    /// terminal has the keyboard there or not (`terminalReady`); nil when no left workspace's keys wait any more, or when
    /// the window shows the workspace the person did not leave (``shownWorkspaceToWaitFor``): the hold ends there, and the
    /// left one's keys go with it as before (review of #32352: keys typed into that shown workspace waited up to 2 s).
    public func keysKeptForLeftWorkspace(shown: String?, terminalReady: Bool) -> Int? {
        if let current = shownWorkspaceToWaitFor, current == shown { return nil }
        guard let left = leftWorkspaceWithKeys, left.workspace != shown || !terminalReady else { return nil }
        return left.ticket
    }
}
