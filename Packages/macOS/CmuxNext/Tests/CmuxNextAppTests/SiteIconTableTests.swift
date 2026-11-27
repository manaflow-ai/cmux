import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Observation
import Testing

/// THE ICON ADDRESS OF A SITE, AFTER EACH CHANGE OF THE OPEN TABS.
///
/// A bookmark, a recent page of the New Tab page and a row of a browser's omnibar draw the icon that an open tab of
/// the same site shows: the first open, not incognito, browser tab of the site in the order of the workspaces, else
/// the site's own `/favicon.ico` (`AppServices.siteFaviconAddress(origin:)`). A wrong icon there is a fault that a
/// person sees. These rows hold the answer after each change of the open tabs.
///
/// THE ORACLE (``walk(_:origin:)``) is the body that the function had when it walked each workspace at each
/// question, kept here word for word. Each row compares the product's answer with it, and rows 1 to 5 also with the
/// address that the row's own scene gives. Row 6 does it after each of some hundred random steps, and also compares
/// the oracle with the scene's own model.
///
/// Each change of the open tabs is one snapshot of the tree, as the app gets its tabs. After a change the rows let
/// the main actor run (a fixed number of yields), then ask. No clock.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct SiteIconTableTests {
    /// Counts the runs of a tracking's `onChange`.
    private nonisolated final class Counter: @unchecked Sendable {
        var count = 0
    }

    /// One browser tab of the scene.
    private struct Page {
        let surface: UInt64
        /// The number of the page's site (``siteName(_:)``).
        var site: Int
        /// The icon address that the tab shows; nil: none yet.
        var icon: String?
    }

    /// One workspace of the scene: one screen, one pane, one terminal and its pages.
    private struct Space {
        let number: UInt64
        let key: WorkspaceKey
        let terminal: UInt64
        var pages: [Page] = []
    }

    /// The row's own model of the open tabs. No id of a workspace or of a tab is used twice.
    private struct Scene {
        var spaces: [Space] = []
        var surfaces: UInt64 = 0
        var numbers: UInt64 = 0

        /// A new workspace at the end of the list. Returns its place.
        @discardableResult mutating func addSpace(key: WorkspaceKey? = nil) -> Int {
            numbers += 1
            surfaces += 1
            spaces.append(Space(number: numbers, key: key ?? WorkspaceKey(rawValue: "site-icon-ws-\(numbers)"), terminal: surfaces))
            return spaces.count - 1
        }

        /// A new page at the end of the workspace at `space`.
        mutating func addPage(_ space: Int, site: Int, icon: String?) {
            surfaces += 1
            spaces[space].pages.append(Page(surface: surfaces, site: site, icon: icon))
        }

        /// The scene as the daemon's tree.
        var tree: DaemonTree {
            let workspaces = spaces.map { space in
                let pages = space.pages.map {
                    TabSnapshot(surface: SurfaceID(rawValue: $0.surface), kind: .browser, url: SiteIconTableTests.siteName($0.site) + "/page", faviconURL: $0.icon)
                }
                let pane = PaneSnapshot(id: PaneID(rawValue: space.number), tabs: [TabSnapshot(surface: SurfaceID(rawValue: space.terminal), title: "zsh")] + pages)
                let screen = ScreenSnapshot(id: ScreenID(rawValue: space.number), layout: .leaf(pane.id), panes: [pane])
                return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: space.number), key: space.key, name: "workspace \(space.number)", screens: [screen])
            }
            return DaemonTree(workspaces: workspaces)
        }

        /// The model's answer for site `site`: the icon of the first page of the site that has one, in the order of
        /// the workspaces, else the site's own address. `without`: a workspace that the answer leaves out.
        func address(of site: Int, without secret: WorkspaceKey? = nil) -> String {
            let pages = spaces.filter { $0.key != secret }.flatMap(\.pages)
            return pages.first { $0.site == site && $0.icon != nil }?.icon ?? SiteIconTableTests.ownAddress(site)
        }
    }

    /// A fixed sequence of numbers from a seed (SplitMix64): the same steps at each run.
    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        /// A number from 0 to `bound` - 1.
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// The kinds of steps of row 6.
    private enum Kind: String, CaseIterable {
        case openTab = "open a tab"
        case goToSite = "go to a site"
        case iconArrives = "an icon arrives"
        case closeTab = "close a tab"
        case closeWorkspace = "close a workspace"
        case newWorkspace = "a new workspace"
    }

    private static let siteCount = 6
    private static let mostSpaces = 6
    private static let mostPages = 3
    private static let steps = 300

    private static func siteName(_ number: Int) -> String { "https://site-\(number).example" }
    private static func ownAddress(_ number: Int) -> String { siteName(number) + "/favicon.ico" }
    private static func iconAddress(_ number: Int, _ name: String) -> String { siteName(number) + "/icon-\(name).png" }

    /// THE ORACLE: the walk over each workspace of this Mac to the first open tab of the site, as
    /// `AppServices.siteFaviconAddress(origin:)` did it at each question.
    private static func walk(_ services: AppServices, origin: String) -> String {
        let open = services.machines.local.store.workspaces.lazy.flatMap { services.openTabFavicons(of: $0) }
        return open.first { $0.origin == origin }?.address ?? origin + "/favicon.ico"
    }

    /// An app with no window on the screen.
    private static func app() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        return services
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    private static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// Gives `scene` to the app's store as one snapshot, then lets the main actor run. `secret`: the workspace that
    /// its daemon flags ephemeral (one of the 3 facts that make a workspace incognito). A snapshot lays the daemon's
    /// state over each workspace again, and this store has none, so the flag is set again after each snapshot, in
    /// the same turn.
    private static func show(_ scene: Scene, in services: AppServices, secret: WorkspaceKey? = nil) async {
        services.daemon.store.apply(snapshot: scene.tree)
        if let secret {
            services.daemon.store.workspace(id: secret.rawValue)?.applyState(ephemeral: true, status: nil, screenGroups: nil)
        }
        await drainMain()
    }

    /// The product's answers for the sites `numbers`. Each one is compared with the oracle's.
    private static func answers(_ services: AppServices, _ numbers: [Int], _ state: String) -> [String] {
        numbers.map { number in
            let kept = services.siteFaviconAddress(origin: siteName(number))
            let walked = walk(services, origin: siteName(number))
            #expect(kept == walked, "\(state): the icon address of site \(number) is \(kept), the walk gives \(walked)")
            return kept
        }
    }

    /// Row 1, a tab's site changes: the tab's old site has its own address again, the new site has the tab's icon.
    @Test func aTabThatGoesToAnotherSiteTakesItsIconWithIt() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")
        #expect(Self.answers(services, [1, 2], "at the start") == [Self.iconAddress(1, "a"), Self.ownAddress(2)])
        scene.spaces[0].pages[0].site = 2
        scene.spaces[0].pages[0].icon = Self.iconAddress(2, "a")
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1, 2], "after the tab went to site 2") == [Self.ownAddress(1), Self.iconAddress(2, "a")])
    }

    /// Row 2, a tab closes: the next open tab of the site gives its icon; with no tab left the site has its own.
    @Test func aClosedTabGivesTheSitesIconToTheNextTab() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: Self.iconAddress(1, "a"))
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "b"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")
        #expect(Self.answers(services, [1], "at the start") == [Self.iconAddress(1, "a")])
        scene.spaces[0].pages.removeAll()
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the first tab closed") == [Self.iconAddress(1, "b")])
        scene.spaces[1].pages.removeAll()
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the second tab closed") == [Self.ownAddress(1)])
    }

    /// Row 3, a workspace closes: its tabs' icons go out, and a later workspace's tab of the site takes the place.
    @Test func aClosedWorkspaceTakesItsIconsOut() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: Self.iconAddress(1, "a"))
        scene.addPage(0, site: 2, icon: Self.iconAddress(2, "a"))
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "b"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")
        #expect(Self.answers(services, [1, 2], "at the start") == [Self.iconAddress(1, "a"), Self.iconAddress(2, "a")])
        scene.spaces.remove(at: 0)
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 1, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 1")
        #expect(Self.answers(services, [1, 2], "after the first workspace closed") == [Self.iconAddress(1, "b"), Self.ownAddress(2)])
    }

    /// Row 4, an icon arrives late: a tab with a site and no icon address gives the site's own; then its address.
    @Test func anIconThatArrivesLateIsTheSitesIcon() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: nil)
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 1, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 1")
        #expect(Self.answers(services, [1], "before the icon") == [Self.ownAddress(1)])
        scene.spaces[0].pages[0].icon = Self.iconAddress(1, "a")
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the icon arrived") == [Self.iconAddress(1, "a")])
        scene.spaces[0].pages[0].icon = Self.iconAddress(1, "b")
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the page changed its icon") == [Self.iconAddress(1, "b")])
    }

    /// Row 5, a restart: a new app over the same open tabs gives the same answers, at its first question with no
    /// turn of the main actor after the tabs came, and later. A third app is asked before its tabs come. The answer
    /// is made from the open tabs each time: the product stores no file for it.
    @Test func aNewAppOverTheSameOpenTabsGivesTheSameIcons() async throws {
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: Self.iconAddress(1, "a"))
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "b"))
        scene.addPage(1, site: 2, icon: Self.ownAddress(2))
        scene.addPage(2, site: 3, icon: nil)
        scene.addPage(2, site: 4, icon: Self.iconAddress(4, "a"))
        let want = [Self.iconAddress(1, "a"), Self.ownAddress(2), Self.ownAddress(3), Self.iconAddress(4, "a"), Self.ownAddress(5)]
        let first = Self.app()
        await Self.show(scene, in: first)
        try #require(first.machines.local.store.workspaces.count == 3, "fixture: this Mac's store has \(first.machines.local.store.workspaces.count) workspaces, not 3")
        #expect(Self.answers(first, [1, 2, 3, 4, 5], "the first app") == want)

        let second = Self.app()
        second.daemon.store.apply(snapshot: scene.tree)
        #expect(Self.answers(second, [1, 2, 3, 4, 5], "the second app, its first question, no turn after its tabs") == want)
        await Self.drainMain()
        #expect(Self.answers(second, [1, 2, 3, 4, 5], "the second app, later") == want)

        let third = Self.app()
        #expect(Self.answers(third, [1, 2, 3, 4, 5], "the third app, before its tabs") == [1, 2, 3, 4, 5].map { Self.ownAddress($0) })
        await Self.show(scene, in: third)
        #expect(Self.answers(third, [1, 2, 3, 4, 5], "the third app, after its tabs came") == want)
    }

    /// One of the 4 icon states of a new page of site `number`.
    private static func someIcon(_ number: Int, _ random: inout Generator) -> String? {
        switch random.below(4) {
        case 0: return nil
        case 1: return ownAddress(number)
        case 2: return iconAddress(number, "a")
        default: return iconAddress(number, "b")
        }
    }

    /// One random step on `scene`. A kind that the scene cannot take now (no page to close, a full list) becomes
    /// another kind; the kind that ran comes back. The workspace with the key `secret` is never closed.
    private static func step(_ scene: inout Scene, _ random: inout Generator, secret: WorkspaceKey) -> Kind {
        var kind = Kind.allCases[random.below(Kind.allCases.count)]
        let withPages = scene.spaces.indices.filter { !scene.spaces[$0].pages.isEmpty }
        let withRoom = scene.spaces.indices.filter { scene.spaces[$0].pages.count < mostPages }
        let normal = scene.spaces.indices.filter { scene.spaces[$0].key != secret }
        if kind == .closeWorkspace, normal.count <= 2 { kind = .newWorkspace }
        if kind == .newWorkspace, scene.spaces.count >= mostSpaces { kind = .closeTab }
        if kind == .goToSite || kind == .iconArrives || kind == .closeTab, withPages.isEmpty { kind = .openTab }
        if kind == .openTab, withRoom.isEmpty { kind = .closeTab }
        switch kind {
        case .openTab:
            let space = withRoom[random.below(withRoom.count)]
            let number = 1 + random.below(siteCount)
            let icon = someIcon(number, &random)
            scene.addPage(space, site: number, icon: icon)
        case .goToSite:
            let space = withPages[random.below(withPages.count)]
            let page = random.below(scene.spaces[space].pages.count)
            let number = 1 + random.below(siteCount)
            scene.spaces[space].pages[page].site = number
            // The new page of the tab has no icon yet, or it has one already.
            scene.spaces[space].pages[page].icon = random.below(2) == 0 ? nil : iconAddress(number, "a")
        case .iconArrives:
            let space = withPages[random.below(withPages.count)]
            let page = random.below(scene.spaces[space].pages.count)
            let number = scene.spaces[space].pages[page].site
            let icons = [ownAddress(number), iconAddress(number, "a"), iconAddress(number, "b")]
            scene.spaces[space].pages[page].icon = icons[random.below(icons.count)]
        case .closeTab:
            let space = withPages[random.below(withPages.count)]
            let page = random.below(scene.spaces[space].pages.count)
            scene.spaces[space].pages.remove(at: page)
        case .closeWorkspace:
            scene.spaces.remove(at: normal[random.below(normal.count)])
        case .newWorkspace:
            scene.addSpace()
        }
        return kind
    }

    /// Row 6, the fuzz: after EACH random step, for EACH site, the product's answer is the oracle's, and the oracle's
    /// is the scene's own model's. 3 fixed seeds; the second workspace of each scene is incognito (its daemon flags
    /// it ephemeral). The row is not empty: at its end each kind of step ran, the oracle's answer changed 20 times or
    /// more, and an incognito tab hid an icon that a walk over all tabs gives.
    @Test func afterEachRandomStepEachSitesIconIsTheWalks() async throws {
        for seed: UInt64 in [1, 2, 3] {
            let services = Self.app()
            let secret = WorkspaceKey(rawValue: "site-icon-secret-\(seed)")
            var scene = Scene()
            scene.addSpace()
            scene.addSpace(key: secret)
            scene.addSpace()
            await Self.show(scene, in: services, secret: secret)
            try #require(services.machines.local.store.workspaces.count == 3, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 3")
            try #require(services.daemon.store.workspace(id: secret.rawValue)?.ephemeral == true, "fixture: the second workspace is not flagged ephemeral")
            var random = Generator(state: seed)
            var ran: [String: Int] = [:]
            var changes = 0
            var hidden = 0
            var faults = 0
            var before = (1...Self.siteCount).map { Self.walk(services, origin: Self.siteName($0)) }
            for number in 1...Self.steps where faults == 0 {
                let kind = Self.step(&scene, &random, secret: secret)
                ran[kind.rawValue, default: 0] += 1
                await Self.show(scene, in: services, secret: secret)
                for site in 1...Self.siteCount {
                    let kept = services.siteFaviconAddress(origin: Self.siteName(site))
                    let walked = Self.walk(services, origin: Self.siteName(site))
                    let model = scene.address(of: site, without: secret)
                    if walked != before[site - 1] { changes += 1 }
                    before[site - 1] = walked
                    if scene.address(of: site) != walked { hidden += 1 }
                    if kept != walked || walked != model {
                        faults += 1
                        Issue.record("seed \(seed), step \(number) (\(kind.rawValue)), site \(site): the product answers \(kept), the walk \(walked), the scene's model \(model)")
                    }
                }
            }
            let kinds = Kind.allCases.map { "\($0.rawValue) \(ran[$0.rawValue, default: 0])" }.joined(separator: ", ")
            let fewest = Kind.allCases.map { ran[$0.rawValue, default: 0] }.min() ?? 0
            print("SiteIconTableTests: row 6, the fuzz, seed \(seed): \(Self.steps) steps (\(kinds)); the walk's answer changed \(changes) times; an incognito tab hid an icon in \(hidden) answers; \(faults) faults")
            guard faults == 0 else { continue }
            try #require(fewest >= 1, "seed \(seed): a kind of step did not run: \(kinds)")
            try #require(changes >= 20, "seed \(seed): the walk's answer changed \(changes) times, fewer than 20")
            try #require(hidden >= 1, "seed \(seed): no incognito tab hid an icon")
        }
    }

    /// Row 8, a reader of the old answer is woken: a reader asks for a site's icon inside observation tracking; then
    /// the icon arrives, or the tab goes to another site. After the main actor ran, the reader's change handler ran,
    /// and a new question gives the oracle's answer. An old icon for some turns is no fault; an old icon with no wake
    /// is one.
    @Test func aReaderOfTheOldIconIsWoken() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addPage(0, site: 1, icon: nil)
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 1, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 1")
        // One question outside a tracking first: a reader of the app is not the first one that asks.
        #expect(Self.answers(services, [1], "before the icon") == [Self.ownAddress(1)])

        let late = Counter()
        let old = withObservationTracking { services.siteFaviconAddress(origin: Self.siteName(1)) } onChange: { late.count += 1 }
        try #require(old == Self.ownAddress(1), "fixture: the icon address before the icon is \(old)")
        scene.spaces[0].pages[0].icon = Self.iconAddress(1, "a")
        await Self.show(scene, in: services)
        #expect(late.count >= 1, "the icon arrived and the reader of the old address was not woken")
        #expect(Self.answers(services, [1], "after the icon arrived") == [Self.iconAddress(1, "a")])

        let moved = Counter()
        let shown = withObservationTracking { services.siteFaviconAddress(origin: Self.siteName(1)) } onChange: { moved.count += 1 }
        try #require(shown == Self.iconAddress(1, "a"), "fixture: the icon address before the tab's move is \(shown)")
        scene.spaces[0].pages[0].site = 2
        scene.spaces[0].pages[0].icon = nil
        await Self.show(scene, in: services)
        #expect(moved.count >= 1, "the tab went to another site and the reader of its old site's icon was not woken")
        #expect(Self.answers(services, [1, 2], "after the tab went to site 2") == [Self.ownAddress(1), Self.ownAddress(2)])
        print("SiteIconTableTests: row 8: the reader's change handler ran \(late.count) time(s) after the icon arrived and \(moved.count) time(s) after the tab's move")
    }

    /// Row 9, a workspace turns incognito after its page gave an icon (the daemon's flag can come after the tree):
    /// after the main actor ran, the site has its own address again, and a reader of the page's icon was woken.
    @Test func aWorkspaceThatTurnsIncognitoTakesItsIconOut() async throws {
        let services = Self.app()
        let secret = WorkspaceKey(rawValue: "site-icon-turns-secret")
        var scene = Scene()
        scene.addSpace()
        scene.addSpace(key: secret)
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")
        #expect(Self.answers(services, [1], "before the flag") == [Self.iconAddress(1, "a")])

        let turned = Counter()
        let shown = withObservationTracking { services.siteFaviconAddress(origin: Self.siteName(1)) } onChange: { turned.count += 1 }
        try #require(shown == Self.iconAddress(1, "a"), "fixture: the icon address before the flag is \(shown)")
        try #require(services.daemon.store.workspace(id: secret.rawValue)).applyState(ephemeral: true, status: nil, screenGroups: nil)
        await Self.drainMain()
        #expect(turned.count >= 1, "the workspace turned incognito and the reader of its page's icon was not woken")
        #expect(Self.answers(services, [1], "after the workspace turned incognito") == [Self.ownAddress(1)])
    }

    /// Row 11, the same turn by the window registry's own cell: an incognito window lists the workspace after its
    /// page gave an icon, then that window closes while the daemon still lists the workspace. After the main actor
    /// ran, the site has its own address at each of the 2 states.
    @Test func aWorkspaceThatAnIncognitoWindowListsTakesItsIconOut() async throws {
        let services = Self.app()
        let secret = WorkspaceKey(rawValue: "site-icon-listed-secret")
        var scene = Scene()
        scene.addSpace()
        scene.addSpace(key: secret)
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "before a window lists the workspace") == [Self.iconAddress(1, "a")])

        _ = services.windows.registry.apply {
            $0.markIncognito("w-site-icon-secret")
            return $0.openWindow(id: "w-site-icon-secret", workspaceIDs: [secret.rawValue])
        }
        await Self.drainMain()
        #expect(Self.answers(services, [1], "listed by an incognito window") == [Self.ownAddress(1)])
        _ = services.windows.registry.apply { $0.close("w-site-icon-secret") }
        await Self.drainMain()
        #expect(Self.answers(services, [1], "its incognito window closed") == [Self.ownAddress(1)])
    }

    /// Row 12, the question in the SAME TURN as the turn to incognito, on a table that a question started before it:
    /// the site has its own address at once, as the walk gave it. No turn of the main actor is between the turn to
    /// incognito and the question, so the table still has the page's icon: the right answer needs the question's own
    /// read of that workspace's incognito facts. Two apps: the daemon's flag (the turn of row 9), then the window
    /// registry's cell and that window's close (the turns of row 11). Each app's scene has one tab of the site.
    @Test func inTheTurnOfTheTurnToIncognitoTheSiteHasItsOwnAddress() async throws {
        let flagged = Self.app()
        let secret = WorkspaceKey(rawValue: "site-icon-same-turn-flag")
        var scene = Scene()
        scene.addSpace()
        scene.addSpace(key: secret)
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(scene, in: flagged)
        try #require(flagged.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(flagged.machines.local.store.workspaces.count) workspaces, not 2")
        try #require(Self.answers(flagged, [1], "before the flag") == [Self.iconAddress(1, "a")], "fixture: the table has no icon of the page before the flag")
        await Self.drainMain()
        try #require(flagged.daemon.store.workspace(id: secret.rawValue)).applyState(ephemeral: true, status: nil, screenGroups: nil)
        #expect(Self.answers(flagged, [1], "in the turn of the daemon's flag") == [Self.ownAddress(1)])
        await Self.drainMain()
        #expect(Self.answers(flagged, [1], "after the daemon's flag and a run of the main actor") == [Self.ownAddress(1)])

        let listed = Self.app()
        let other = WorkspaceKey(rawValue: "site-icon-same-turn-listed")
        var second = Scene()
        second.addSpace()
        second.addSpace(key: other)
        second.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(second, in: listed)
        try #require(listed.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(listed.machines.local.store.workspaces.count) workspaces, not 2")
        try #require(Self.answers(listed, [1], "before a window lists the workspace") == [Self.iconAddress(1, "a")], "fixture: the table has no icon of the page before the window")
        await Self.drainMain()
        _ = listed.windows.registry.apply {
            $0.markIncognito("w-site-icon-same-turn")
            return $0.openWindow(id: "w-site-icon-same-turn", workspaceIDs: [other.rawValue])
        }
        #expect(Self.answers(listed, [1], "in the turn in which an incognito window lists the workspace") == [Self.ownAddress(1)])
        _ = listed.windows.registry.apply { $0.close("w-site-icon-same-turn") }
        #expect(Self.answers(listed, [1], "in the turn of that window's close") == [Self.ownAddress(1)])
        await Self.drainMain()
        #expect(Self.answers(listed, [1], "after that window's close and a run of the main actor") == [Self.ownAddress(1)])
    }

    /// Row 13, 2 tabs of one site in ONE workspace: the first tab gives the site's icon. After it closes, the second
    /// tab of the same workspace gives it. After that one closes, the site has its own address.
    @Test func theSecondTabOfASiteInOneWorkspaceGivesTheIconAfterTheFirstCloses() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "b"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")
        #expect(Self.answers(services, [1], "at the start") == [Self.iconAddress(1, "a")])
        scene.spaces[1].pages.removeFirst()
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the first tab of the workspace closed") == [Self.iconAddress(1, "b")])
        scene.spaces[1].pages.removeAll()
        await Self.show(scene, in: services)
        #expect(Self.answers(services, [1], "after the second tab of the workspace closed") == [Self.ownAddress(1)])
    }

    /// Row 10, the first question of an app comes from a reader inside observation tracking: no window and no
    /// question before it. The answer is the right icon. After a change of the icon the reader's change handler ran
    /// one time (a tracking calls its handler one time at most), and a new question gives the oracle's answer. The
    /// row prints what the observed lists read in the turn of that first question, and if the reader was woken
    /// before the change.
    @Test func theFirstQuestionInsideATrackingGivesTheRightIconAndOneWake() async throws {
        let services = Self.app()
        var scene = Scene()
        scene.addSpace()
        scene.addSpace()
        scene.addPage(1, site: 1, icon: Self.iconAddress(1, "a"))
        await Self.show(scene, in: services)
        try #require(services.machines.local.store.workspaces.count == 2, "fixture: this Mac's store has \(services.machines.local.store.workspaces.count) workspaces, not 2")

        let first = Counter()
        let work = ObservationWork()
        let shown = ObservationWork.$current.withValue(work) {
            withObservationTracking { services.siteFaviconAddress(origin: Self.siteName(1)) } onChange: { first.count += 1 }
        }
        let walked = Self.walk(services, origin: Self.siteName(1))
        #expect(shown == Self.iconAddress(1, "a"), "the first question, inside a tracking, gave \(shown)")
        #expect(shown == walked, "the first question, inside a tracking, gave \(shown), the walk gives \(walked)")
        let reads = work.byStep.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        await Self.drainMain()
        let early = first.count

        scene.spaces[1].pages[0].icon = Self.iconAddress(1, "b")
        await Self.show(scene, in: services)
        #expect(first.count == 1, "the icon changed and the change handler of the first question's reader ran \(first.count) times, not 1")
        #expect(Self.answers(services, [1], "after the page changed its icon") == [Self.iconAddress(1, "b")])
        print("SiteIconTableTests: row 10: 2 workspaces: the observed lists read in the turn of the first question: [\(reads)]; the reader was woken \(early) time(s) before the change and \(first.count) time(s) in all")
    }
}
