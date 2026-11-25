@testable import CmuxNextAgentActivity
@testable import CmuxNextComputerUse
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The live preview card's app name (its accessible label) and done icon (B6): the legacy helper
/// names only the app's process, so the card looks the app up for its name and icon, and never
/// says "Unknown app". A done card hides itself after ``ComputerUseLivePreview/autoHideDelay``.
@MainActor
struct ComputerUsePreviewAppTests {
    static let frame = "data:image/jpeg;base64,AA=="
    static let icon = "data:image/png;base64,AA=="
    static let calculator = ComputerUsePreviewApp.Key(bundleID: nil, pid: 40846)

    /// A session as the legacy helper reports it: a process, no app name, no bundle id.
    static func session(live: Bool = true, app: String? = nil, pid: Int32? = 40846, title: String? = nil,
                        acts: Int = 1) -> ComputerUsePreviewSession {
        ComputerUsePreviewSession(id: "s", live: live, app: app, pid: pid, windowTitle: title, agentKind: "claude",
                                  lastActionAt: Date(timeIntervalSince1970: 100), steps: acts)
    }

    /// A board with `session` running in chat `a`, its frame loaded.
    static func board(_ session: ComputerUsePreviewSession) -> ComputerUsePreviewBoard {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [session])
        board.route(chats: [ComputerUsePreviewBoardTests.chat("a", working: true)])
        board.apply(newestFrame: "b1", at: ComputerUsePreviewBoardTests.at(1), session: "s")
        board.loaded(.init(id: "b1", at: ComputerUsePreviewBoardTests.at(1), url: frame), session: "s")
        return board
    }

    // MARK: The title

    @Test func theDriversNameWins() {
        let board = Self.board(Self.session(app: "Calculator"))
        #expect(board.card(for: "a", apps: [Self.calculator: .init(name: "Other", icon: nil)])?.app == "Calculator")
    }

    @Test func aProcessOnlySessionTakesTheLookedUpName() {
        let board = Self.board(Self.session())
        #expect(board.appKeys == [Self.calculator])
        #expect(board.card(for: "a", apps: [Self.calculator: .init(name: "Calculator", icon: Self.icon)])?.app == "Calculator")
    }

    @Test func withNoNameTheWindowTitleThenNoTitle() {
        let titled = Self.board(Self.session(title: "Untitled 3"))
        #expect(titled.card(for: "a")?.app == "Untitled 3")
        let bare = Self.board(Self.session(pid: nil, title: "  "))
        #expect(bare.appKeys.isEmpty)
        #expect(bare.card(for: "a")?.app == "", "the page's label names no app; it never says Unknown app")
    }

    @Test func theIconComesWithTheDoneStateOnly() {
        var board = Self.board(Self.session())
        let apps = [Self.calculator: ComputerUsePreviewApp(name: "Calculator", icon: Self.icon)]
        #expect(board.card(for: "a", apps: apps)?.icon == nil)
        board.apply(sessions: [Self.session(live: false)])
        #expect(board.card(for: "a", apps: apps) == ComputerUsePreviewCard(session: "s", app: "Calculator", done: true,
                                                                            frame: Self.frame, icon: Self.icon))
    }

    // MARK: The wire

    @Test func theWireReadsTheTargetsProcessAndWindowTitle() throws {
        let json: [String: Any] = [
            "id": "cua_n_1", "agent": ["kind": "cmux"], "status": ["state": "active"],
            "targets": [["pid": 40846, "window_id": 58714, "title_redacted": "Calculator"]],
        ]
        let session = try #require(AgentActivityWire.session(json, machine: "local", machineName: "This Mac"))
        #expect(session.targetPID == 40846)
        #expect(session.targetWindowTitle == "Calculator")
        #expect(session.targetApp == nil)
        let bare = try #require(AgentActivityWire.session(["id": "x", "targets": [["pid": 0]]], machine: "local", machineName: "M"))
        #expect(bare.targetPID == nil)
    }

    // MARK: The AppKit lookup

    @Test func aBundleIdResolvesToTheAppsNameAndASmallPNGIcon() async throws {
        let app = try #require(await ComputerUseWorkspaceAppResolver().resolve(.init(bundleID: "com.apple.calculator", pid: nil)))
        #expect(app.name?.isEmpty == false)
        #expect(app.icon?.hasPrefix("data:image/png;base64,") == true)
        #expect((app.icon?.utf8.count ?? .max) < 64 << 10, "small enough to send with each done card")
    }

    @Test func aProcessThatIsGoneOrAnotherAppsResolvesToNothingOfIts() async {
        let resolver = ComputerUseWorkspaceAppResolver()
        #expect(await resolver.resolve(.init(bundleID: nil, pid: Int32.max)) == nil)
        #expect(await resolver.resolve(.init(bundleID: "com.example.no-such-app", pid: Int32.max)) == nil)
    }

    // MARK: The live preview looks the app up

    @Test(.timeLimit(.minutes(1)))
    func theLivePreviewLooksTheAppUpAndSendsItsIconWhenDone() async throws {
        let host = FakeHost()
        let resolver = FakeResolver(apps: [Self.calculator: .init(name: "Calculator", icon: Self.icon)])
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: resolver)
        preview.set(enabled: true)
        preview.apply(.sessions([Self.session()]))
        preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        let running = try #require(await host.next { $0?.app == "Calculator" && $0?.done == false })
        #expect(running?.icon == nil)
        preview.apply(.sessions([Self.session(live: false)]))
        let done = try #require(await host.next { $0?.done == true })
        #expect(done == ComputerUsePreviewCard(session: "s", app: "Calculator", done: true, frame: Self.frame, icon: Self.icon))
        #expect(await resolver.asked == [Self.calculator], "one lookup per app")
    }

    @Test(.timeLimit(.minutes(1)))
    func anAppNoOneAnswersForShowsNoTitle() async throws {
        let host = FakeHost()
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: FakeResolver(apps: [:]))
        preview.set(enabled: true)
        preview.apply(.sessions([Self.session()]))
        preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        let card = try #require(await host.next { $0 != nil })
        #expect(card?.app == "")
    }

    // MARK: The live preview reads the chats only when routing can change

    @Test(.timeLimit(.minutes(1)))
    func frameNoticesReadNoChats() async throws {
        let host = FakeHost()
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: FakeResolver(apps: [:]))
        preview.set(enabled: true)
        preview.apply(.sessions([Self.session()]))
        let reads = host.chatReads
        for (index, frame) in ["b1", "b2", "b3"].enumerated() {
            preview.apply(.newestFrame(session: "s", frame: frame, at: ComputerUsePreviewBoardTests.at(Double(index))))
            _ = try #require(await host.next { $0 != nil })
        }
        #expect(host.chatReads == reads, "a frame notice and its load push to the routed chat only")
        #expect(host.shownChats == ["a"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aTabThatSwitchesChatLosesTheOldChatsCardAtOnce() async throws {
        let host = FakeHost()
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: FakeResolver(apps: [:]))
        preview.set(enabled: true)
        preview.apply(.sessions([Self.session()]))
        preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await host.next { $0 != nil })
        // `chat.select` in tab a: it now shows an idle chat, and the helper sends nothing new.
        host.chats = [ComputerUsePreviewBoardTests.chat("a", session: "acp-other"), ComputerUsePreviewBoardTests.chat("b")]
        host.chatsChanged()
        #expect(try #require(await host.next { $0 == nil }) == nil)
    }

    // MARK: A done card hides itself

    /// A live preview on `clock` with session `s` running in chat `a`, its card shown.
    private static func running(on clock: ManualClock) async throws -> (FakeHost, ComputerUseLivePreview) {
        let host = FakeHost()
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: FakeResolver(apps: [:]),
                                             clock: clock)
        preview.set(enabled: true)
        preview.apply(.sessions([Self.session()]))
        preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await host.next { $0?.done == false })
        return (host, preview)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDoneCardHidesItselfAfterThirtySecondsAsIfClosed() async throws {
        let clock = ManualClock()
        let (host, preview) = try await Self.running(on: clock)
        #expect(clock.sleeperCount == 0, "a running card is never timed")
        preview.apply(.sessions([Self.session(live: false)]))
        _ = try #require(await host.next { $0?.done == true })
        try await clock.waitForSleeper()
        #expect(preview.autoHides == ["a"])
        clock.advance(by: ComputerUseLivePreview.autoHideDelay - .seconds(1))
        #expect(clock.sleeperCount == 1, "not before the delay")
        clock.advance(by: .seconds(1))
        #expect(try #require(await host.next { $0 == nil }) == nil)
        #expect(preview.autoHides.isEmpty)
        #expect(preview.board.entries["s"]?.autoHidden == true)
        #expect(preview.board.entries["s"]?.dismissed == false, "only the person's close keeps a session hidden")
    }

    /// The driver keeps a session open between turns: a hidden card's session that acts again on a
    /// later turn shows its card again (before, the hide was the close's path and it stayed hidden).
    @Test(.timeLimit(.minutes(1)))
    func aLaterActOfTheSameSessionShowsTheHiddenCardAgain() async throws {
        let clock = ManualClock()
        let (host, preview) = try await Self.running(on: clock)
        preview.apply(.sessions([Self.session(live: false)]))
        _ = try #require(await host.next { $0?.done == true })
        try await clock.waitForSleeper()
        clock.advance(by: ComputerUseLivePreview.autoHideDelay)
        #expect(try #require(await host.next { $0 == nil }) == nil)
        preview.apply(.sessions([Self.session(acts: 2)]))
        _ = try #require(await host.next { $0?.done == false })
        #expect(preview.board.entries["s"]?.autoHidden == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewActBeforeTheDelayCancelsTheHide() async throws {
        let clock = ManualClock()
        let (host, preview) = try await Self.running(on: clock)
        preview.apply(.sessions([Self.session(live: false)]))
        _ = try #require(await host.next { $0?.done == true })
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(20))
        // The agent acts again in the same chat: the card runs and the hide is off.
        preview.apply(.sessions([Self.session(acts: 2)]))
        _ = try #require(await host.next { $0?.done == false })
        #expect(clock.sleeperCount == 0)
        #expect(preview.autoHides.isEmpty)
        clock.advance(by: .seconds(20))
        #expect(preview.board.entries["s"]?.dismissed == false)
        // Done again: a new full delay.
        preview.apply(.sessions([Self.session(live: false, acts: 2)]))
        _ = try #require(await host.next { $0?.done == true })
        try await clock.waitForSleeper()
        clock.advance(by: ComputerUseLivePreview.autoHideDelay)
        #expect(try #require(await host.next { $0 == nil }) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCloseBeforeTheDelayLeavesNothingScheduled() async throws {
        let clock = ManualClock()
        let (host, preview) = try await Self.running(on: clock)
        preview.apply(.sessions([Self.session(live: false)]))
        _ = try #require(await host.next { $0?.done == true })
        try await clock.waitForSleeper()
        host.click(session: "s", .close)
        #expect(try #require(await host.next { $0 == nil }) == nil)
        #expect(clock.sleeperCount == 0)
        #expect(preview.autoHides.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneChatsHideLeavesAnotherChatsCard() async throws {
        let clock = ManualClock()
        let host = FakeHost()
        let preview = ComputerUseLivePreview(host: host, makeSource: { FakeSource() }, resolver: FakeResolver(apps: [:]),
                                             clock: clock)
        preview.set(enabled: true)
        let s = ComputerUsePreviewBoardTests.session("s", acp: "acp-a")
        var t = ComputerUsePreviewBoardTests.session("t", acp: "acp-b")
        preview.apply(.sessions([s, t]))
        preview.apply(.newestFrame(session: "s", frame: "s1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await host.next(in: "a") { $0 != nil })
        preview.apply(.newestFrame(session: "t", frame: "t1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await host.next(in: "b") { $0 != nil })
        // Chat a turns done; chat b still runs.
        var ended = s
        ended.live = false
        preview.apply(.sessions([ended, t]))
        _ = try #require(await host.next(in: "a") { $0?.done == true })
        try await clock.waitForSleeper()
        #expect(preview.autoHides == ["a"])
        // Chat a's delay ends: only its card goes.
        clock.advance(by: ComputerUseLivePreview.autoHideDelay)
        #expect(try #require(await host.next(in: "a") { $0 == nil }) == nil)
        #expect(host.current["b"]??.done == false, "chat b still shows its running card")
        #expect(preview.board.entries["t"]?.dismissed == false)
        #expect(preview.autoHides.isEmpty)
        // Chat b turns done: its own delay, from now.
        t.live = false
        preview.apply(.sessions([ended, t]))
        _ = try #require(await host.next(in: "b") { $0?.done == true })
        try await clock.waitForSleeper()
        clock.advance(by: ComputerUseLivePreview.autoHideDelay)
        #expect(try #require(await host.next(in: "b") { $0 == nil }) == nil)
    }
}

/// Chat `a` working, chat `b` idle; each card shown goes to `next`.
@MainActor
private final class FakeHost: ComputerUseLivePreviewHost {
    private var shown: [(chat: String, card: ComputerUsePreviewCard?)] = []
    /// How many times the live preview read the chats.
    private(set) var chatReads = 0
    /// The chats a card was shown in.
    private(set) var shownChats: Set<String> = []
    /// Each chat's card as last shown (nil: taken off).
    private(set) var current: [String: ComputerUsePreviewCard?] = [:]
    private var respond: (@MainActor (String, ComputerUsePreviewClick) -> Void)?
    private var waiter: (chat: String?, match: (ComputerUsePreviewCard?) -> Bool,
                         continuation: CheckedContinuation<ComputerUsePreviewCard??, Never>)?

    /// The chats the host has; a test changes them and calls `chatsChanged`.
    var chats = [ComputerUsePreviewBoardTests.chat("a", working: true), ComputerUsePreviewBoardTests.chat("b")]
    private(set) var chatsChanged: @MainActor () -> Void = {}

    func computerUsePreviewChats() -> [ComputerUsePreviewChat] {
        chatReads += 1
        return chats
    }
    func computerUsePreviewFollowChats(_ changed: @escaping @MainActor () -> Void) { chatsChanged = changed }
    func computerUsePreviewOpenActivity(session: String) {}

    func computerUsePreviewShow(_ card: ComputerUsePreviewCard?, in chat: String,
                                respond: @escaping @MainActor (String, ComputerUsePreviewClick) -> Void) {
        shown.append((chat, card))
        shownChats.insert(chat)
        current[chat] = .some(card)
        self.respond = respond
        if let waiter, waiter.chat == nil || waiter.chat == chat, waiter.match(card) {
            // Taken: the next wait starts after this card.
            self.waiter = nil
            shown.removeAll()
            waiter.continuation.resume(returning: .some(card))
        }
    }

    /// A click on the card of `session`, as the page sends it.
    func click(session: String, _ click: ComputerUsePreviewClick) { respond?(session, click) }

    /// The first card shown (already or later, in `chat` when given) that `match` takes; nil when
    /// the test's time limit cancels the wait, so a card that never comes fails the test.
    func next(in chat: String? = nil, _ match: @escaping (ComputerUsePreviewCard?) -> Bool) async -> ComputerUsePreviewCard?? {
        if let index = shown.firstIndex(where: { shown in (chat == nil || shown.chat == chat) && match(shown.card) }) {
            let card = shown[index].card
            shown.removeFirst(index + 1)
            return .some(card)
        }
        shown.removeAll()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume(returning: nil) }
                waiter = (chat, match, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWait() }
        }
    }

    private func cancelWait() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}

/// Answers every frame at once.
@MainActor
private final class FakeSource: ComputerUseLivePreviewSource {
    func start(_ sink: @escaping @MainActor (ComputerUseLivePreviewUpdate) -> Void) {}
    func stop() {}
    func follow(session: String, _ on: Bool) {}
    func frame(_ frame: String) async -> String? { ComputerUsePreviewAppTests.frame }
}

/// Answers from a fixed table and records what it was asked.
private actor FakeResolver: ComputerUsePreviewAppResolving {
    let apps: [ComputerUsePreviewApp.Key: ComputerUsePreviewApp]
    private(set) var asked: [ComputerUsePreviewApp.Key] = []

    init(apps: [ComputerUsePreviewApp.Key: ComputerUsePreviewApp]) { self.apps = apps }

    func resolve(_ key: ComputerUsePreviewApp.Key) async -> ComputerUsePreviewApp? {
        asked.append(key)
        return apps[key]
    }
}
