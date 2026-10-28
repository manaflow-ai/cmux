import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing
import UniformTypeIdentifiers

/// The Home list at launch (Lawrence 2026-10-21: "loading stat here is bad on app launch"): every
/// input of the list beyond the conversations (each owner's order and pins, each Chief's avatar and
/// engine, the archived Chiefs, the cloud Chiefs' Main and places) arrives on its own after launch.
/// The first frame must already be the list as it was at the last quit, and each live answer that
/// says the same must not move, resize or redraw a row.
@MainActor
@Suite(.serialized) struct HomeLaunchListTests {
    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    static let account = "acct_lawrence"

    /// The conversations as the store has them from its cache at launch: summaries without a newest
    /// message (so no preview of their own), in the store's order.
    static func storeRows() -> [InboxRow] {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func chief(_ id: String, _ name: String, _ minutes: Double) -> CmuxHomeCore.ConversationSummary {
            let agent = Participant(id: ParticipantID(id), kind: .agent, displayName: name, agentClass: .chief)
            return CmuxHomeCore.ConversationSummary(id: ConversationID("conv_\(id)"), title: name, participants: [me, agent],
                                       createdAt: at, updatedAt: at.addingTimeInterval(minutes * 60))
        }
        let austin = Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin Wang")
        let tina = Participant(id: ParticipantID("user_tina"), kind: .human, displayName: "Tina")
        let summaries = [
            chief("agent_mux", "Chief", 50),
            chief("agent_hosted", "Chief", 40),
            chief("agent_unii", "Unii", 5),
            chief("agent_old", "Old Chief", 60),
            CmuxHomeCore.ConversationSummary(id: ConversationID("conv_austin"), title: "", participants: [me, austin], createdAt: at,
                                updatedAt: at.addingTimeInterval(30 * 60)),
            CmuxHomeCore.ConversationSummary(id: ConversationID("conv_pulse"), title: "Team Pulse", participants: [me, austin, tina],
                                createdAt: at, updatedAt: at.addingTimeInterval(20 * 60)),
        ]
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    static func reply(_ json: String) throws -> HomeInboxRequest.Response {
        try JSONDecoder().decode(HomeInboxRequest.Response.self, from: Data(json.utf8))
    }

    /// The owners' answers: the local owner pins both Chiefs and Austin and names the rows; the
    /// Cloud owner lists Team Pulse with its preview.
    static func liveReplies() throws -> (local: HomeInboxRequest.Response, cloud: HomeInboxRequest.Response) {
        let local = try reply("""
        {"me":"user_me","cloud":"not_asked","rows":[
         {"id":"conv_agent_mux","kind":"chief","name":"Chief","unread":0,"activity_at":"2027-01-15T08:50:00Z","preview":"On it.","pinned":true,"pin_position":1,"marked_unread":false,"owner":"local"},
         {"id":"conv_agent_hosted","kind":"chief","name":"Chief","unread":0,"activity_at":"2027-01-15T08:40:00Z","preview":"Deployed.","pinned":true,"pin_position":2,"marked_unread":false,"owner":"local"},
         {"id":"conv_austin","kind":"direct","name":"Austin Wang","unread":0,"activity_at":"2027-01-15T08:30:00Z","preview":"lgtm","pinned":true,"pin_position":3,"marked_unread":false,"owner":"local"},
         {"id":"conv_agent_unii","kind":"chief","name":"Unii","unread":0,"activity_at":"2027-01-15T08:05:00Z","preview":"we need the ios and android simulator stuff built into cmux","pinned":false,"marked_unread":false,"owner":"local"}
        ]}
        """)
        let cloud = try reply("""
        {"me":"user_me","cloud":"included","rows":[
         {"id":"conv_pulse","kind":"group","name":"Team Pulse","unread":0,"activity_at":"2027-01-15T08:20:00Z","preview":"Standup moved to 10","pinned":false,"marked_unread":false,"owner":"cloud"}
        ]}
        """)
        return (local, cloud)
    }

    static let liveAvatars: [String: HomeChiefAvatar] = ["agent_mux": .text("🐱"), "agent_hosted": .text("CH")]
    static let liveHarnesses: [String: String] = ["agent_unii": "uniichat"]
    static let liveArchived: Set<String> = ["agent_old"]
    static let fallbackAvatar = HomeChiefAvatar.text("🫡")

    /// The app's roster before the cloud Chiefs are read (every Chief on this Mac, the local one Main)
    /// and after (the Hosted Chief is Main and runs in the Cloud).
    static func roster(rows: [InboxRow], cloudRead: Bool) -> HomeChiefRoster {
        HomeChiefRoster.make(rows: rows, local: ConversationID("conv_agent_mux"),
                             hosted: cloudRead ? ConversationID("conv_agent_hosted") : nil, placed: nil, server: nil, showsPlaced: false)
    }

    /// The launch the source's closures read (set once the launch is made).
    @MainActor final class Ref { weak var launch: Launch? }

    /// One launch of the list: its inputs as the app holds them, each live answer applied in turn.
    @MainActor final class Launch {
        let local = HomeInboxSource(owners: ["local"])
        let cloud = HomeInboxSource(owners: ["cloud"])
        var avatars: [String: HomeChiefAvatar] = [:]
        var harnesses: [String: String] = [:]
        var archived: Set<String> = []
        var cloudRead = false
        var lastRoster: HomeChiefRoster?
        let source: HomeSidebarSource
        let defaults: UserDefaults

        init() {
            let suite = "cmux.tests.homeLaunchList.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let ref = Ref()
            let rows: @MainActor @Sendable () -> [InboxRow] = {
                TopHomePageView.visible(HomeLaunchListTests.storeRows(), archivedChiefs: ref.launch?.archived ?? [], me: HomeLaunchListTests.me.id)
            }
            source = HomeSidebarSource(
                store: HomePinStore(defaults: defaults), inboxes: [local, cloud], account: { HomeLaunchListTests.account },
                rows: rows, me: { HomeLaunchListTests.me.id }, contacts: { [] },
                chiefAvatars: { ref.launch?.avatars ?? [:] }, defaultChiefAvatar: { HomeLaunchListTests.fallbackAvatar },
                chiefHarnesses: { ref.launch?.harnesses ?? [:] },
                chiefRoster: {
                    let cloudRead = ref.launch?.cloudRead ?? false
                    let live = HomeLaunchListTests.roster(rows: rows(), cloudRead: cloudRead)
                    guard !cloudRead, let last = ref.launch?.lastRoster else { return live }
                    return live.launching(last: last)
                })
            ref.launch = self
        }

        /// The app's `primeHomeList`: the last launch's state for what has not answered yet.
        func prime(_ cache: HomeSidebarLaunchCache) {
            guard let last = cache.load(account: HomeLaunchListTests.account) else { return }
            last.seed([local, cloud])
            if archived.isEmpty { archived = last.archivedChiefs }
            if avatars.isEmpty { avatars = last.chiefAvatars }
            if harnesses.isEmpty { harnesses = last.chiefHarnesses }
            lastRoster = last.roster
        }

        func model() -> HomeSidebarModel { source.model(now: Date(timeIntervalSince1970: 1_800_010_000)) }

        /// The live answers in the order they land after launch, each with the model it gives.
        func settle() throws -> [(String, HomeSidebarModel)] {
            let live = try HomeLaunchListTests.liveReplies()
            var frames: [(String, HomeSidebarModel)] = [("first frame", model())]
            local.accept(live.local); frames.append(("local owner", model()))
            cloud.accept(live.cloud); frames.append(("cloud owner", model()))
            avatars = HomeLaunchListTests.liveAvatars; harnesses = HomeLaunchListTests.liveHarnesses
            frames.append(("avatars, engines", model()))
            archived = HomeLaunchListTests.liveArchived; frames.append(("archived Chiefs", model()))
            cloudRead = true; frames.append(("cloud Chiefs", model()))
            return frames
        }
    }

    /// A cache file holding the list as the last session left it (that session settled, then quit).
    static func lastSession() throws -> HomeSidebarLaunchCache {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-launch-\(UUID().uuidString)/sidebar.json")
        let cache = HomeSidebarLaunchCache(url: url, files: BackgroundWork(label: "test.home-launch"))
        let last = Launch()
        _ = try last.settle()
        cache.save(last.source.launchSnapshot(archivedChiefs: last.archived))
        cache.flush()
        return HomeSidebarLaunchCache(url: url, files: BackgroundWork(label: "test.home-launch"))
    }

    @Test func theFirstFrameIsTheListAsTheLastSessionLeftIt() throws {
        let cache = try Self.lastSession()
        let launch = Launch()
        launch.prime(cache)
        let frames = try launch.settle()
        let settled = try #require(frames.last).1
        #expect(settled.pinned.map(\.title) == ["Chief", "Chief", "Austin Wang"])
        for (stage, model) in frames {
            #expect(model == settled, "the list at \(stage) differs from the settled list")
        }
    }

    @Test func aRowTheCacheKnowsWithoutItsNewestMessageShowsTheOwnersPreview() throws {
        let launch = Launch()
        _ = try launch.settle()
        let pulse = try #require(launch.model().rows.first { $0.title == "Team Pulse" })
        #expect(pulse.preview == "Standup moved to 10")
    }

    @Test func anotherAccountsListIsNeverShown() throws {
        let cache = try Self.lastSession()
        #expect(cache.load(account: "acct_someone_else") == nil)
        #expect(cache.load(account: Self.account) != nil)
    }

    @Test func noRowMovesOrPopsInWhileTheLiveAnswersLand() throws {
        let cache = try Self.lastSession()
        let launch = Launch()
        launch.prime(cache)
        let (view, window) = Self.host()
        defer { window.close() }
        var layouts: [[String]] = []
        for (_, model) in try launch.settle() {
            view.update(model)
            view.layoutSubtreeIfNeeded()
            layouts.append(view.itemFramesInWindow.map { "\($0.id.rawValue) \($0.pinned) \(NSStringFromRect($0.frame))" })
        }
        #expect(!(layouts.first ?? []).isEmpty)
        #expect(Set(layouts).count == 1, "the rows moved between launch stages: \(layouts)")
    }

    // MARK: Frames (for people: `.build/home-launch-frames.png`, before on the left, after on the right)

    static func host() -> (HomeSidebarView, NSWindow) {
        _ = NSApplication.shared
        let view = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    static func render(_ model: HomeSidebarModel) -> CGImage? {
        let (view, window) = host()
        defer { window.close() }
        view.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
        view.update(model)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    @Test func launchFrames() throws {
        let cache = try Self.lastSession()
        let before = Launch()
        let after = Launch()
        after.prime(cache)
        let columns = try [before.settle(), after.settle()].map { $0.compactMap { Self.render($0.1) } }
        let cell = try #require(columns.first?.first)
        let gap = 16
        let rows = columns.map(\.count).max() ?? 0
        let width = cell.width * 2 + gap * 3
        let height = (cell.height + gap) * rows + gap
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (c, column) in columns.enumerated() {
            for (r, image) in column.enumerated() {
                let y = height - (r + 1) * (cell.height + gap)
                ctx.draw(image, in: CGRect(x: gap + c * (cell.width + gap), y: y, width: image.width, height: image.height))
            }
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-launch-frames.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
