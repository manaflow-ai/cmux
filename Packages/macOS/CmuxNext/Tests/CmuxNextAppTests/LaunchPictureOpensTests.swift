import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p08-startup-096: something opened from another app while the launch window shows its picture waits for the pane it
/// lands in, never for startup completion: the window's build raises for it, so the focused pane is the first pane
/// built, the open goes once right after it shows, and the picture over that pane drops. An open that comes before the
/// first frame (before the build exists) raises the build once it starts. The real phase, regions and build over
/// `LaunchWindowBuildTests`' fake window and panes; the startup queue run by hand.
@MainActor @Suite(.serialized) struct LaunchPictureOpensTests {
    typealias Rig = LaunchWindowBuildTests.Rig

    /// `ExternalOpenController`'s queue: an open is held while the launch picture holds it, and the held queue runs
    /// once each time it is woken, if nothing holds it any more.
    final class Opener {
        let opens: LaunchPictureOpens
        let target: () -> any LaunchWindowPane
        private(set) var pending = 0
        /// Each tab made, with whether the target pane was shown when it was.
        private(set) var made: [Bool] = []
        private let isShown: () -> Bool

        init(opens: LaunchPictureOpens, target: @escaping () -> any LaunchWindowPane, isShown: @escaping () -> Bool) {
            self.opens = opens
            self.target = target
            self.isShown = isShown
        }

        func open() {
            guard !opens.holds({ [weak self] in self?.flush() }) else {
                pending += 1
                return
            }
            deliver()
        }

        func flush() {
            guard pending > 0, !opens.holds({ [weak self] in self?.flush() }) else { return }
            let waiting = pending
            pending = 0
            for _ in 0..<waiting { deliver() }
        }

        private func deliver() {
            made.append(isShown())
            opens.opened(in: target())
        }
    }

    /// What the closures under test record (a class: they are main-actor closures that escape).
    final class Record {
        var values: [Bool] = []
    }

    static let left = LaunchWindowBuildTests.left
    static let right = LaunchWindowBuildTests.right

    private static func opener(_ launch: Rig) -> Opener {
        let pane = launch.panes[0]
        return Opener(opens: LaunchPictureOpens(phase: launch.phase), target: { pane }, isShown: { !pane.shownIn.isEmpty })
    }

    /// An open-URL before the first frame: held while no build exists, it raises the build once the build starts, and
    /// the tab is made once, in the raised slice, right after the focused pane shows and before any other pane does.
    @Test func anOpenBeforeTheFirstFrameMakesItsTabOnceRightAfterTheFocusedPaneShows() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let opener = Self.opener(launch), opens = opener.opens, pane = launch.panes[0]

        opener.open()
        #expect(opener.pending == 1 && opener.made.isEmpty, "the open went before its pane existed")
        #expect(launch.window.mountedIn.isEmpty, "the open built the window in its own turn")
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.tabStrips)"])

        opens.buildStarted(launch.build)
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.tabStrips)", "\(LaunchWindowBuild.raised)"],
                "the held open raises the build as a key does")

        launch.slices.runNext()  // the strips
        #expect(opener.made.isEmpty, "the open went before the focused pane showed")
        launch.slices.runNext()  // raised: the focused pane
        #expect(opener.made == [true], "the tab is made once, right after its pane shows")
        #expect(launch.panes[1].shownIn.isEmpty, "the focused pane is the first pane built")
        #expect(!launch.regions.covers(pane.center), "the picture over the opened pane stayed up")
        #expect(launch.regions.covers(launch.panes[1].center), "the other pane keeps its part until it draws")

        launch.slices.runAll()
        launch.phase.buildFinished()
        opener.flush()
        #expect(opener.made == [true], "the open made its tab again")
        #expect(opener.pending == 0)
    }

    /// Once the focused pane shows, an open goes in its own turn: nothing holds it and its pane's part drops.
    @Test func anOpenAfterTheFocusedPaneShowsGoesAtOnce() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let opener = Self.opener(launch)
        opener.opens.buildStarted(launch.build)
        launch.slices.runNext()
        launch.slices.runNext()  // the focused pane
        #expect(launch.build.isOpenReady)
        opener.open()
        #expect(opener.made == [true] && opener.pending == 0)
        #expect(!launch.regions.covers(launch.panes[0].center))
        #expect(launch.slices.queuedNames.allSatisfy { $0 != "\(LaunchWindowBuild.raised)" }, "a ready window was raised")
    }

    /// No picture after all (none in time, a mismatch, its window closed first): the held open goes once the window is
    /// built on today's path.
    @Test func withNoPictureAfterAllTheOpenGoesOnceTheWindowIsBuilt() throws {
        let deadlines = MainDeadlineRig()
        let phase = LaunchPicturePhase(deadlines: deadlines.deadlines) { _ in }
        let opens = LaunchPictureOpens(phase: phase)
        let woken = Record()
        #expect(opens.holds { woken.values.append(true) })
        phase.skip()
        #expect(woken.values.count == 1)
        #expect(!opens.holds { woken.values.append(false) }, "a built window still holds opens")
        #expect(woken.values == [true], "a held open was woken twice")
    }

    /// An open whose pane has no part of its own (the picture shows another page or layout there) takes the whole
    /// picture away at once.
    @Test func anOpenOutsideEveryPartTakesThePictureAway() throws {
        let launch = try Rig(areas: [Self.left])
        defer { launch.tearDown() }
        launch.slices.runAll()
        let elsewhere = LaunchWindowBuildTests.Pane(CGRect(x: 0, y: 695, width: 1100, height: 20), slices: launch.slices)
        LaunchPictureOpens(phase: launch.phase).opened(in: elsewhere)
        #expect(launch.phase.picture == nil, "the picture stayed over a pane it does not show")
    }

    /// A dropped part leaves as undrawn: the clicks held on it are dropped (`LaunchPictureInput`), never sent to the
    /// content the open put there.
    @Test func aDroppedPartLeavesUndrawn() throws {
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        launch.slices.runAll()
        let left = Record()
        launch.regions.partLeft = { _, drawn in left.values.append(drawn) }
        #expect(launch.regions.drop(at: launch.panes[0].center))
        #expect(left.values == [false])
        #expect(!launch.regions.drop(at: Rig.titleRow), "the rest is no part of its own")
    }

    /// The sign-in callback goes to Cloud auth in the URL's own turn, before anything that waits for a window or the
    /// launch picture: it is never queued as an open.
    @Test func anAuthCallbackNeverWaitsForTheLaunchWindow() throws {
        var opened = 0
        let callback = try #require(URL(string: "cmux-dev://auth-callback?code=1"))
        let destination = OpenedURLRouting.route(callback, isAuthCallback: { $0 == callback }, open: { _ in
            opened += 1
            return true
        })
        #expect(destination == .auth)
        #expect(opened == 0)
    }
}
