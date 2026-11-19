import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Row 15. A hold of New Tab keys, the Close Tab key on the last tab before the daemon answered that tab's creation,
/// and then the daemon's answer. Row 14's form `not answered` ends at the Close Tab key: its request never goes to the
/// daemon. This row sends it: the request for the 6th tab waits in the row until the Close Tab key was taken, then it
/// goes to the daemon of this tree, and the daemon's answer comes back to the app for a tab that the person closed.
///
/// Want, when the answer came back and one frame later: the strip is the list that it was after the Close Tab key
/// (the closed tab did not come back, and the daemon's tab is not in it); the pane shows the same tab, with the page
/// view of the hold, in the pane's window, not hidden, with the keyboard in it; no page view was made; the app did
/// not report the daemon's tab as the tab that the closed one became (`AgentTabStore.moveSelection` with the closed tab's
/// key: 0 calls). Last: the daemon's own list of tabs does not have the daemon's tab 10 seconds later at most. The
/// daemon made that tab (its answer names the tab's surface), so its list loses the tab only when the app asks the
/// daemon to close it. The row reads that list by a request to the daemon (`DaemonConnection.listWorkspaces`), and
/// requires that the same reads have the tab that the pane shows.
///
/// Setup, not a want: the store had the creation as a cancelled one when the answer came back.
///
/// Printed only, each with the words `not a proof here`: if the app has a page view or a New Tab page under the
/// closed tab's key or under the daemon's tab's key after the answer, and if the store lists the daemon's tab. The
/// app can let go of the closed tab's page state before the answer, and the store can hide the daemon's tab from its
/// first event, so these 2 reads can say the same with a fault and with none.
///
/// Limits. The request leaves the app after the Close Tab key, because the row holds it; in the app it can be on
/// its way at the key. The answer comes after the key in both. The keys are as in row 14.
extension NewTabHoldMovesItsPageTests {
    /// What the row records of the creation that it holds.
    @MainActor final class LateAnswer {
        /// How many creations the app asked for while the row held them.
        var requests = 0
        /// Whether the store has the held creation as a cancelled one, read when it is called.
        var cancelled: @MainActor () -> Bool = { false }
        /// The daemon's answer, and what the row read in the turn in which it came back.
        var created: AgentTabCreated?
        var cancelledAtTheAnswer = false, listedAtTheAnswer = false
        var stripAtTheAnswer: [String] = []
        /// Why the daemon made no tab, when it made none.
        var failure: String?
        /// The keys of the tabs that the app reported as created (`AgentTabStore.moveSelection`), in the calls' order.
        var moves: [String] = []

        var done: Bool { created != nil || failure != nil }
    }

    /// What the daemon's own list of tabs said of one tab over the reads of a wait.
    struct DaemonsList {
        var reads = 0
        /// Whether the list had the tab at the first read and at the last one; nil when the daemon gave no answer.
        var first: Bool?, last: Bool?
        /// Whether a read had the tab that the pane shows: the proof that the reads see the pane's tabs.
        var seesTheShownTab = false

        static func word(_ has: Bool?) -> String { has.map { $0 ? "yes" : "no" } ?? "no answer" }
    }

    /// Reads the daemon's list of tabs until it does not have the tab with `surface`, for 10 seconds at most. It does
    /// not throw when the daemon gives no answer.
    static func daemonsList(of surface: SurfaceID, shown: SurfaceID?, on connection: DaemonConnection) async -> DaemonsList {
        var list = DaemonsList()
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            if list.reads > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            let tree = try? await connection.listWorkspaces()
            let surfaces = tree.map { tree in tree.workspaces.flatMap { $0.screens }.flatMap { $0.panes }.flatMap { $0.tabs }.map { $0.surface } }
            list.last = surfaces.map { $0.contains(surface) }
            if list.reads == 0 { list.first = list.last }
            if let surfaces, let shown, surfaces.contains(shown) { list.seesTheShownTab = true }
            list.reads += 1
        } while list.last != false && ContinuousClock.now < deadline
        return list
    }

    @Test func anAnswerForATabThatACloseTabKeyClosedChangesNothingThatThePaneShows() async throws {
        try await Self.row("cn-hold-moves-page-late-answer") { services, pane, views, _ in
            let tabs = services.agentTabs, router = services.keyRouter, store = pane.daemon.store, creations = store.creations
            let held = await Self.hold(5, in: pane, services, views)
            try #require(held.pressed == 5 && held.made == 0,
                         "setup: the hold of 5 New Tab keys pressed \(held.pressed) keys and made \(held.made) page views, want 5 and 0")
            // Each tab of the hold is the daemon's before the 6th key: the tab that the pane shows after the close has
            // a key that no answer changes.
            try await PasswordManagerRouteTests.until({ pane.orderedIDs.allSatisfy { !creations.isPending(tab: $0.rawValue) } },
                                                      within: .seconds(10), report: { "setup: the daemon did not answer each creation of the 5 keys" })
            await NewTabPageAtItsFrameTests.frame(services)
            let page = try #require(pane.currentTabKey.flatMap { tabs.existingView($0) }, "setup: the tab of the 5th key has no page view")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            let connection = try #require(pane.daemon.connection, "setup: the pane's daemon has no connection")
            // The request for each tab from here on waits in the row, then goes to the daemon as the app sends it.
            let gate = NewTabHoldInTheFirstNewTabTests.HeldCreations(), late = LateAnswer(), create = tabs.create, move = tabs.moveSelection
            tabs.create = { handle, daemon, record, key, transaction, split in
                late.requests += 1
                late.cancelled = { store.creations.wasCancelled(transaction) }
                await gate.wait()
                do {
                    let made = try await create(handle, daemon, record, key, transaction, split)
                    // The turn in which the answer came back, before the app's own code for it.
                    late.cancelledAtTheAnswer = late.cancelled()
                    late.listedAtTheAnswer = store.liveTreeLists(tab: made.created.key) == true
                    late.stripAtTheAnswer = pane.orderedIDs.map(\.rawValue)
                    late.created = made.created
                    return made
                } catch {
                    late.failure = String(describing: error)
                    throw error
                }
            }
            tabs.moveSelection = { provisional, surface in
                late.moves.append(provisional)
                move(provisional, surface)
            }
            defer {
                tabs.create = create
                tabs.moveSelection = move
                gate.release()
            }
            // The 6th New Tab key, as the app gets a key, with the keyboard in the page.
            if (window.firstResponder as? NSView)?.isDescendant(of: page.webView) != true { _ = try Self.keyboard(to: page, in: pane) }
            let strip = pane.orderedIDs.count
            let sixth = try Self.keyDown("t", code: 17, command: true, in: window)
            page.judge(sixth, eventWindow: window)
            let tookTheSixth = router.dispatchingSynthetic(sixth) { router.interceptKeyDown(sixth, in: window) }
            try #require(tookTheSixth, "setup: the key router passed the 6th New Tab key on")
            try #require(pane.orderedIDs.count == strip + 1, "setup: the 6th New Tab key added \(pane.orderedIDs.count - strip) tabs to the strip, want 1")
            await NewTabPageAtItsFrameTests.frame(services)
            try await PasswordManagerRouteTests.until({ late.requests > 0 }, within: .seconds(10),
                                                      report: { "setup: the app did not ask for the creation of the 6th tab" })
            try #require(late.requests == 1, "setup: the app asked for \(late.requests) creations after the 6th key, want 1")
            let closed = try #require(pane.currentTabKey, "setup: the pane shows no tab before the Close Tab key")
            try #require(creations.isPending(tab: closed), "setup: the store does not have the 6th tab as a creation that waits, one frame after its key")
            try #require(tabs.isNewTabPage(closed) && closed == pane.stripModel.selectedID?.rawValue,
                         "setup: the pane does not show the New Tab tab that the strip selects before the Close Tab key")
            try #require(tabs.existingView(closed) === page, "setup: the 6th tab does not have the page view of the hold before the Close Tab key")
            if (window.firstResponder as? NSView)?.isDescendant(of: page.webView) != true { _ = try Self.keyboard(to: page, in: pane) }

            // The Close Tab key, before the answer: row 14 has the wants of its turn, here they are the setup.
            let atTheKey = try Self.closeTabKey(page, in: pane, services, views, window: window)
            try #require(atTheKey.wasPending && atTheKey.faults.isEmpty,
                         "setup: the Close Tab key before the answer (its tab was a creation that waits: \(atTheKey.wasPending)): \(CloseRead.words(atTheKey.faults))")
            try #require(late.cancelled(), "setup: the store does not have the creation as a cancelled one after the Close Tab key")
            try #require(!late.done, "setup: the creation that the row holds had its answer before the row let it go")
            let stripAfterTheKey = pane.orderedIDs.map(\.rawValue), shownAfterTheKey = pane.currentTabKey, madeBefore = views.count
            let shownSurface = pane.pane.tabs.first { $0.id == shownAfterTheKey }?.surface
            let wasAPageBefore = tabs.isNewTabPage(closed), movesBefore = late.moves.filter { $0 == closed }.count

            // The request goes to the daemon now, and its answer comes back for a tab that the person closed.
            gate.release()
            try await PasswordManagerRouteTests.until({ late.done }, within: .seconds(10),
                                                      report: { "setup: the daemon did not answer the creation of the 6th tab" })
            let created = try #require(late.created, "setup: the daemon made no tab for the 6th key: \(late.failure ?? "no reason")")
            await NewTabPageAtItsFrameTests.frame(services)
            let after = Self.shows(page, in: pane, services, window: window)
            _ = views.read(pane, services)
            let stripAfterTheAnswer = pane.orderedIDs.map(\.rawValue), made = views.count - madeBefore
            let moves = late.moves.filter { $0 == closed }.count - movesBefore
            let pageOfTheDaemonsTab = tabs.isNewTabPage(created.key) || tabs.existingView(created.key) != nil
            let pageOfTheClosedTab = tabs.isNewTabPage(closed) || tabs.existingView(closed) != nil
            let daemons = await Self.daemonsList(of: created.surface, shown: shownSurface, on: connection)
            let listedAtTheEnd = store.liveTreeLists(tab: created.key) == true
            print("""
                NewTabHoldMovesItsPageTests: row 15, an answer for the 6th tab of a hold after its Close Tab key: the store had the \
                creation as a cancelled one at the answer: \(late.cancelledAtTheAnswer); the strip had \(stripAfterTheKey.count) tabs \
                after the key, \(late.stripAtTheAnswer.count) at the answer, \(stripAfterTheAnswer.count) one frame later; the pane one \
                frame later: \(CloseRead.words(after.showFaults)); \(made) page views made; \(moves) reports of a created tab for the \
                closed tab; the daemon's list had its tab at the first read: \(DaemonsList.word(daemons.first)), at the last of \
                \(daemons.reads) reads: \(DaemonsList.word(daemons.last)), and the reads had the tab that the pane shows: \
                \(daemons.seesTheShownTab). Not a proof here: the app had the closed tab as a New Tab page before the answer: \
                \(wasAPageBefore); a page or a New Tab page under the closed tab's key after it: \(pageOfTheClosedTab), under the \
                daemon's tab's key: \(pageOfTheDaemonsTab); the store listed the daemon's tab at the answer: \
                \(late.listedAtTheAnswer), at the row's end: \(listedAtTheEnd)
                """)
            try #require(late.cancelledAtTheAnswer, "setup: the store did not have the creation as a cancelled one when the answer came back")
            #expect(late.stripAtTheAnswer == stripAfterTheKey,
                    "the strip changed between the Close Tab key and the answer: \(stripAfterTheKey.count) tabs, then \(late.stripAtTheAnswer.count)")
            #expect(stripAfterTheAnswer == stripAfterTheKey,
                    "the strip changed with the answer for the closed tab: \(stripAfterTheKey.count) tabs after the key, \(stripAfterTheAnswer.count) one frame after the answer")
            #expect(!stripAfterTheAnswer.contains(created.key) && !stripAfterTheAnswer.contains(closed),
                    "the strip has the closed tab or the daemon's tab of its creation, one frame after the answer")
            #expect(pane.currentTabKey == shownAfterTheKey, "the pane shows another tab after the answer than after the Close Tab key")
            #expect(after.showFaults.isEmpty, "one frame after the answer for the closed tab: \(after.showFaults)")
            #expect(made == 0, "\(made) page views made between the Close Tab key and one frame after the answer, want 0")
            #expect(moves == 0, "the app reported a created tab for the closed tab \(moves) times after its Close Tab key, want 0")
            #expect(daemons.seesTheShownTab,
                    "setup: no read of the daemon's list of tabs had the tab that the pane shows (\(daemons.reads) reads): the reads prove nothing of the closed tab")
            #expect(daemons.last == false,
                    "the daemon still has the tab of the cancelled creation after \(daemons.reads) reads of its list in 10 seconds: \(DaemonsList.word(daemons.last))")
        }
    }
}
