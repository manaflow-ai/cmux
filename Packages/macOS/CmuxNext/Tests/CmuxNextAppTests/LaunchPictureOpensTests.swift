import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextOnboarding
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p08-startup-096: something opened from another app while the launch window shows its picture waits for the pane it
/// lands in, never for startup completion: the window's build raises for it, so the focused pane is the first pane
/// built, the open goes once right after it shows, and the picture over that pane drops. An open that comes before the
/// first frame (before the build exists) raises the build once it starts. `ExternalOpenController`'s own queue
/// (`ExternalOpenQueue`) over the real phase, regions and build, with `LaunchWindowBuildTests`' fake window and panes;
/// the startup queue run by hand.
@MainActor @Suite(.serialized) struct LaunchPictureOpensTests {
    typealias Rig = LaunchWindowBuildTests.Rig
    typealias Pane = LaunchWindowBuildTests.Pane

    /// The window side of `ExternalOpenController.run`: the route lands in the launch window's focused pane once the
    /// window installed its content; a browser tab is a new tab there, a link lands as `link` says.
    final class ExternalOpens {
        /// A tab an open made: its address, whether its pane was shown then, and the startup post it was made in.
        struct Tab: Equatable {
            let url: URL
            let paneShown: Bool
            let slice: String?
        }

        let phase: LaunchPicturePhase
        let pane: Pane
        /// The window installed its content (`contentDidAppear`): it has a focused pane to open in.
        var hasContent: Bool
        /// Where a `cmux://` link lands: whether it kept the window's workspace and page.
        var linkKeepsPlace = true
        private(set) var tabs: [Tab] = []
        private(set) var links: [URL] = []
        private(set) lazy var queue = ExternalOpenQueue<ExternalOpenRoute>(launchPicture: { [weak self] in self?.phase },
                                                        hasTarget: { [weak self] in self?.hasContent == true },
                                                        run: { [weak self] in self?.run($0) ?? .waits() })

        init(phase: LaunchPicturePhase, pane: Pane, hasContent: Bool) {
            self.phase = phase
            self.pane = pane
            self.hasContent = hasContent
        }

        /// The app over a launch rig: the window installs its content inside the strips' slice and runs the waiting
        /// opens there, as `WindowController.mountLaunchStrips` does through `contentDidAppear`.
        convenience init(_ launch: Rig) {
            self.init(phase: launch.phase, pane: launch.panes[0], hasContent: false)
            launch.window.onMount = { [weak self] in
                self?.hasContent = true
                self?.queue.flush()
            }
        }

        private func run(_ route: ExternalOpenRoute) -> ExternalOpenLanding {
            guard hasContent else { return .waits() }
            switch route {
            case .browserTab(let url):
                tabs.append(Tab(url: url, paneShown: !pane.shownIn.isEmpty, slice: pane.slices.ran.last))
                return .pane(pane)
            case .deepLink(let url):
                links.append(url)
                return ExternalOpenLanding(link: pane, keptPlace: linkKeepsPlace)
            case .terminal, .file, .unsupported:
                return .pane(pane)
            }
        }
    }

    /// What the closures under test record (a class: they are main-actor closures that escape).
    final class Record {
        var values: [Bool] = []
    }

    static let left = LaunchWindowBuildTests.left
    static let right = LaunchWindowBuildTests.right
    static func page() throws -> URL { try #require(URL(string: "https://example.com/opened")) }
    static func link() throws -> URL { try #require(URL(string: "cmux://tab/1")) }

    /// An open-URL before the first frame: held while no build exists and through `launch_picture_shown`, it raises
    /// the build once the build starts. Inside the strips' slice the window installs its content and runs the waiting
    /// opens, which still wait: no tab is made there and the picture stays whole. The tab is made once, in the raised
    /// slice, right after the focused pane shows and before any other pane does, and only that pane's part drops.
    @Test func anOpenBeforeTheFirstFrameMakesItsTabOnceRightAfterTheFocusedPaneShows() throws {
        let page = try Self.page()
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let app = ExternalOpens(launch), pane = launch.panes[0]

        app.queue.open(.browserTab(page))
        #expect(app.queue.pending == [.browserTab(page)] && app.tabs.isEmpty, "the open went before its pane existed")
        #expect(launch.window.mountedIn.isEmpty, "the open built the window in its own turn")
        app.queue.flush()  // launch_picture_shown
        #expect(app.queue.pending.count == 1)
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.tabStrips)"])

        app.queue.launchBuildStarted(launch.build)
        #expect(launch.slices.queuedNames == ["\(LaunchWindowBuild.tabStrips)", "\(LaunchWindowBuild.raised)"],
                "the held open raises the build as a key does")

        launch.slices.runNext()  // the strips: the window's content appears and runs the waiting opens
        #expect(launch.window.mountedIn == [0] && app.hasContent)
        #expect(app.tabs.isEmpty, "the open went in the strips' slice, before its pane showed")
        #expect(app.queue.pending.count == 1)
        #expect(launch.phase.picture != nil, "the picture left over a half-built window")
        #expect(launch.regions.covers(pane.center) && launch.regions.covers(launch.panes[1].center))

        launch.slices.runNext()  // raised: the focused pane
        #expect(app.tabs == [ExternalOpens.Tab(url: page, paneShown: true, slice: "\(LaunchWindowBuild.raised)")],
                "the tab is made once, right after its pane shows")
        #expect(launch.panes[1].shownIn.isEmpty, "the focused pane is the first pane built")
        #expect(launch.phase.picture != nil)
        #expect(!launch.regions.covers(pane.center), "the picture over the opened pane stayed up")
        #expect(launch.regions.covers(launch.panes[1].center), "the other pane keeps its part until it draws")

        launch.slices.runAll()
        launch.phase.buildFinished()
        app.queue.flush()
        #expect(app.tabs.count == 1, "the open made its tab again")
        #expect(app.queue.pending.isEmpty)
    }

    /// Once the focused pane shows, an open goes in its own turn: nothing holds it and its pane's part drops.
    @Test func anOpenAfterTheFocusedPaneShowsGoesAtOnce() throws {
        let page = try Self.page()
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let app = ExternalOpens(launch)
        app.queue.launchBuildStarted(launch.build)
        launch.slices.runNext()
        launch.slices.runNext()  // the focused pane
        #expect(launch.build.isOpenReady)
        app.queue.open(.browserTab(page))
        #expect(app.tabs.count == 1 && app.queue.pending.isEmpty)
        #expect(!launch.regions.covers(launch.panes[0].center))
        #expect(launch.slices.queuedNames.allSatisfy { $0 != "\(LaunchWindowBuild.raised)" }, "a ready window was raised")
    }

    /// A `cmux://` link before the first frame waits like any open; once the focused pane shows it runs, and the part
    /// over that pane drops, since the link may have selected another tab there.
    @Test func aLinkBeforeTheFirstFrameDropsItsPanesPart() throws {
        let link = try Self.link()
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let app = ExternalOpens(launch)
        app.queue.open(.deepLink(link))
        app.queue.launchBuildStarted(launch.build)
        launch.slices.runNext()  // the strips
        #expect(app.links.isEmpty, "the link ran before its pane showed")
        launch.slices.runNext()  // raised: the focused pane
        #expect(app.links == [link])
        #expect(!launch.regions.covers(launch.panes[0].center), "the picture kept showing the pane the link changed")
        #expect(launch.regions.covers(launch.panes[1].center))
    }

    /// A link that moved the window to another workspace or page takes the whole picture away: it shows none of it.
    @Test func aLinkThatMovesTheWindowTakesThePictureAway() throws {
        let link = try Self.link()
        let launch = try Rig(areas: [Self.left, Self.right])
        defer { launch.tearDown() }
        let app = ExternalOpens(launch)
        app.linkKeepsPlace = false
        app.queue.open(.deepLink(link))
        app.queue.launchBuildStarted(launch.build)
        launch.slices.runNext()
        #expect(launch.phase.picture != nil)
        launch.slices.runNext()
        #expect(app.links == [link])
        #expect(launch.phase.picture == nil, "the picture stayed over a workspace it does not show")
    }

    /// No picture after all (none in time, a mismatch, its window closed first): the held open goes once the window is
    /// built on today's path, once.
    @Test func withNoPictureAfterAllTheOpenGoesOnceTheWindowIsBuilt() throws {
        let page = try Self.page()
        let deadlines = MainDeadlineRig(), slices = LaunchWindowBuildTests.Slices()
        let phase = LaunchPicturePhase(deadlines: deadlines.deadlines) { _ in }
        let app = ExternalOpens(phase: phase, pane: Pane(Self.left, slices: slices), hasContent: true)
        app.queue.open(.browserTab(page))
        #expect(app.tabs.isEmpty && app.queue.pending.count == 1)
        phase.skip()
        #expect(app.tabs.count == 1 && app.queue.pending.isEmpty)
        app.queue.open(.browserTab(page))
        #expect(app.tabs.count == 2, "a built window still holds opens")
    }

    /// With no window and no launch picture, the open is queued before the window made for it shows its content,
    /// which runs the queue in the same turn: it opens once.
    @Test func anOpenWithNoWindowRunsWhenTheWindowMadeForItShows() {
        /// The app with no window: an open makes one, whose content runs the queue.
        final class NoWindow {
            var made = 0
            var windowShown = false
            private(set) lazy var queue = ExternalOpenQueue<Int>(launchPicture: { nil },
                                                                 hasTarget: { [weak self] in self?.windowShown == true },
                                                                 run: { [weak self] _ in self?.run() ?? .waits() })

            private func run() -> ExternalOpenLanding {
                guard windowShown else {
                    return .waits(then: { [weak self] in
                        self?.windowShown = true
                        self?.queue.flush()  // the new window's contentDidAppear
                    })
                }
                made += 1
                return .elsewhere
            }
        }
        let app = NoWindow()
        app.queue.open(1)
        #expect(app.made == 1 && app.queue.pending.isEmpty)
    }

    /// One hold wakes its opens once, however often the app asked while it held them.
    @Test func aHoldWakesItsOpensOnce() {
        let deadlines = MainDeadlineRig()
        let phase = LaunchPicturePhase(deadlines: deadlines.deadlines) { _ in }
        let woken = Record()
        let opens = LaunchPictureOpens(phase: phase) { woken.values.append(true) }
        #expect(opens.holds())
        #expect(opens.holds())
        phase.skip()
        #expect(woken.values == [true], "a held open was woken twice")
        #expect(!opens.holds())
    }

    /// An open whose pane has no part of its own (the picture shows another page or layout there) takes the whole
    /// picture away at once.
    @Test func anOpenOutsideEveryPartTakesThePictureAway() throws {
        let launch = try Rig(areas: [Self.left])
        defer { launch.tearDown() }
        launch.slices.runAll()
        let elsewhere = Pane(CGRect(x: 0, y: 695, width: 1100, height: 20), slices: launch.slices)
        LaunchPictureOpens(phase: launch.phase) {}.opened(in: elsewhere)
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
