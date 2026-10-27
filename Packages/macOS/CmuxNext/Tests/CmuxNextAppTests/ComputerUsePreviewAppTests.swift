@testable import CmuxNextAgentActivity
@testable import CmuxNextComputerUse
import Foundation
import Testing

/// The live preview card's title and done icon (B6): the legacy helper names only the app's
/// process, so the card looks the app up for its name and icon, and never says "Unknown app".
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
        board.route(chats: [ComputerUsePreviewBoardTests.chat("a", working: true)], focused: "a")
        board.apply(newestFrame: "b1", session: "s")
        board.loaded(.init(id: "b1", url: frame), session: "s")
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
        #expect(bare.card(for: "a")?.app == "", "the page hides the title row; it never says Unknown app")
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
        preview.apply(.newestFrame(session: "s", frame: "b1"))
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
        preview.apply(.newestFrame(session: "s", frame: "b1"))
        let card = try #require(await host.next { $0 != nil })
        #expect(card?.app == "")
    }
}

/// One chat, `a`, working; each card shown goes to `next`.
@MainActor
private final class FakeHost: ComputerUseLivePreviewHost {
    private var shown: [ComputerUsePreviewCard?] = []
    private var waiter: (match: (ComputerUsePreviewCard?) -> Bool, continuation: CheckedContinuation<ComputerUsePreviewCard??, Never>)?

    func computerUsePreviewChats() -> [ComputerUsePreviewChat] { [ComputerUsePreviewBoardTests.chat("a", working: true)] }
    func computerUsePreviewFocusedChat() -> String? { "a" }
    func computerUsePreviewOpenActivity(session: String) {}

    func computerUsePreviewShow(_ card: ComputerUsePreviewCard?, in chat: String,
                                respond: @escaping @MainActor (String, ComputerUsePreviewClick) -> Void) {
        shown.append(card)
        if let waiter, waiter.match(card) {
            self.waiter = nil
            waiter.continuation.resume(returning: .some(card))
        }
    }

    /// The first card shown (already or later) that `match` takes.
    func next(_ match: @escaping (ComputerUsePreviewCard?) -> Bool) async -> ComputerUsePreviewCard?? {
        if let index = shown.firstIndex(where: match) {
            let card = shown[index]
            shown.removeFirst(index + 1)
            return .some(card)
        }
        shown.removeAll()
        return await withCheckedContinuation { waiter = (match, $0) }
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
