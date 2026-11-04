import CmuxNextAgentActivity
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// What the live preview needs from the App: its agent chats and word when a tab's chat changes,
/// a way to show a card in a chat's page, and Agent Activity.
@MainActor
public protocol ComputerUseLivePreviewHost: AnyObject {
    /// Every agent chat that has a page.
    func computerUsePreviewChats() -> [ComputerUsePreviewChat]
    /// Calls `changed` each time a chat tab's page shows another acpmux session (a new chat's
    /// first, or a `chat.select` switch under the same tab key).
    func computerUsePreviewFollowChats(_ changed: @escaping @MainActor () -> Void)
    /// Shows `card` (nil: none) in chat tab `chat`; a click on it comes back to `respond`.
    func computerUsePreviewShow(_ card: ComputerUsePreviewCard?, in chat: String,
                                respond: @escaping @MainActor (_ session: String, _ click: ComputerUsePreviewClick) -> Void)
    /// Opens Agent Activity on Computer Use session `session`.
    func computerUsePreviewOpenActivity(session: String)
}

/// The live preview card of computer use (B6): while an agent drives an app, its chat shows a small
/// live view of that app at the top right; when the session ends the card keeps the last frame,
/// dimmed, with the app's icon and a check. A click opens Agent Activity on the session; the close
/// button hides the card for that session; `computerUse.livePreview` off shows none. A done card
/// hides itself ``autoHideDelay`` later, as if closed, unless it runs again first.
///
/// Its data comes from a ``ComputerUseLivePreviewSource`` (v1: the legacy helper's activity
/// socket, pushed, never polled); the state is ``ComputerUsePreviewBoard``'s; one frame loads at a
/// time off the main thread, the newest first. While a card runs and the person can see its chat
/// (``ComputerUsePreviewSight``), ``ComputerUseLiveCapture`` streams the window the session acts on
/// and the card shows it live (the per-action frames wait meanwhile); when that fails, the
/// per-action frames go on as before. Each chat gets its card only when it changes. The chats are
/// read only when a route can change (a session list, a carded chat's turn, a tab's chat
/// switch), never per frame: a frame goes to the chat its session is routed to.
@MainActor
public final class ComputerUseLivePreview {
    private weak var host: (any ComputerUseLivePreviewHost)?
    /// Makes the source when the setting turns on (tests pass a fake).
    private let makeSource: @MainActor () -> any ComputerUseLivePreviewSource
    private(set) var board = ComputerUsePreviewBoard()
    private var source: (any ComputerUseLivePreviewSource)?
    private var observation: Task<Void, Never>?
    /// The one frame load in flight, and its session and frame.
    private var loading: (session: String, frame: String, task: Task<Void, Never>)?
    /// Looks up the apps the sessions drive (their names and icons), off the main thread.
    private let resolver: any ComputerUsePreviewAppResolving
    /// The apps looked up (`nil`: no app answered); a few per launch, bounded.
    private var apps: [ComputerUsePreviewApp.Key: ComputerUsePreviewApp?] = [:]
    private var appLoads: Set<ComputerUsePreviewApp.Key> = []
    /// Chats that were given a card, so a card that goes is taken off.
    private var shown: Set<String> = []
    /// Follows the turn state of the acpmux sessions whose chats have a card (``AgentLaneStore``'s
    /// per-session links: a new step does not wake it), so a card turns done when its turn ends.
    private var turnObservation: Task<Void, Never>?
    private var turnSessions: [String] = []
    /// The chats as the last route read them.
    private var chats: [ComputerUsePreviewChat] = []
    /// The clock the done cards' hides wait on (tests pass a manual one).
    private let clock: any Clock<Duration>
    /// Each chat whose card is done: the one-shot deadline that closes it ``autoHideDelay`` later.
    /// Cancelled when the card runs again or goes (closed, setting off, its chat gone).
    private var hides: [String: DemandTimer] = [:]
    /// The live view of the window a running card's session acts on.
    let capture: ComputerUseLiveCapture
    /// Whether the person can see a chat; nil: no live view (the per-action frames only).
    private let sight: (any ComputerUsePreviewSight)?

    /// The most apps kept.
    static let maximumApps = 32
    /// How long a done card stays before it hides itself, as if closed.
    static let autoHideDelay: Duration = .seconds(30)

    /// The chats whose done card waits to hide itself.
    var autoHides: Set<String> { Set(hides.keys) }

    /// - Parameters:
    ///   - host: The App's chats and Agent Activity.
    ///   - makeSource: The data source, made when the setting turns on; by default the legacy
    ///     helper's activity socket while the helper runs.
    ///   - resolver: Looks up an app's name and icon; by default AppKit's running apps and Launch Services.
    ///   - clock: The clock a done card's hide and the live view's frames wait on.
    ///   - capture: The live view; by default the legacy helper's window stream.
    ///   - sight: Whether the person can see a chat; nil turns the live view off.
    public init(host: any ComputerUseLivePreviewHost, makeSource: (@MainActor () -> any ComputerUseLivePreviewSource)? = nil,
                resolver: any ComputerUsePreviewAppResolving = ComputerUseWorkspaceAppResolver(),
                clock: any Clock<Duration> = ContinuousClock(), capture: ComputerUseLiveCapture? = nil,
                sight: (any ComputerUsePreviewSight)? = nil) {
        self.host = host
        self.resolver = resolver
        self.clock = clock
        self.makeSource = makeSource ?? {
            ComputerUseActivityPreviewSource(configuration: { ComputerUseHelperDaemon.shared.configuration })
        }
        self.capture = capture ?? ComputerUseLiveCapture(configuration: { ComputerUseHelperDaemon.shared.configuration },
                                                         helperPID: {
                                                             if case .running(let pid) = ComputerUseHelperDaemon.shared.state { pid } else { nil }
                                                         },
                                                         clock: clock)
        self.sight = sight
        host.computerUsePreviewFollowChats { [weak self] in self?.chatsChanged() }
        self.capture.onFrame = { [weak self] target, frame in self?.liveFrame(target, frame) }
        self.capture.onCursor = { [weak self] session, cursor in self?.liveCursor(cursor, session: session) }
        self.capture.sees = { [weak self] target in self?.sight?.canSee(target.chat) ?? false }
    }

    /// Follows `computerUse.livePreview` for the app's life: on, it reads the source; off, it stops
    /// and every card goes.
    public func follow(_ settings: SettingsController) {
        observation?.cancel()
        // task-owner: lives as long as the app; event-driven (Observation)
        observation = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await on in ObservationStream({ settings.snapshot.computerUse.livePreview }) {
                guard let self, !Task.isCancelled else { return }
                set(enabled: on)
            }
        }
    }

    func set(enabled: Bool) {
        guard enabled != (source != nil) else { return }
        board.enabled = enabled
        if enabled {
            let source = makeSource()
            self.source = source
            source.start { [weak self] update in self?.apply(update) }
        } else {
            source?.stop()
            source = nil
            loading?.task.cancel()
            loading = nil
            chats = []
            followTurns()
            push()
        }
    }

    /// A tab's chat changed: a card routed by the old chat leaves it at once.
    func chatsChanged() {
        guard source != nil else { return }
        reroute()
        loadNext()
        push()
    }

    /// Reads the chats and routes every session again.
    private func reroute() {
        chats = host?.computerUsePreviewChats() ?? []
        board.route(chats: chats)
        followTurns()
    }

    /// Routes again when a carded chat's turn starts or ends; re-armed when those chats change.
    private func followTurns() {
        let routed = board.routedChats
        let sessions = chats.filter { routed.contains($0.key) }.compactMap(\.session).sorted()
        guard sessions != turnSessions else { return }
        turnSessions = sessions
        turnObservation?.cancel()
        turnObservation = nil
        guard !sessions.isEmpty else { return }
        // Armed now, after the route that read these states: the first wake is their next change.
        let (_, later) = ObservationStream.current({ sessions.map { AgentLaneStore.shared.links($0)?.state } })
        // task-owner: lives while a card's chat is followed; event-driven (Observation), re-armed on change
        turnObservation = Task { [weak self] in
            for await _ in later {
                guard let self, !Task.isCancelled else { return }
                reroute()
                push()
            }
        }
    }

    // MARK: Source updates

    func apply(_ update: ComputerUseLivePreviewUpdate) {
        switch update {
        case .sessions(let sessions):
            let before = board.followed
            let read = board.apply(sessions: sessions)
            // A new session, one that acted and one that just ended: ask for their newest frame again
            // (the legacy source reads only the new events); ended or closed ones are not followed after.
            for id in read { source?.follow(session: id, true) }
            for id in before.union(read).subtracting(board.followed) { source?.follow(session: id, false) }
            reroute()
            loadNext()
            push()
        case .newestFrame(let session, let frame, let at):
            // The card changes only once the frame loads.
            board.apply(newestFrame: frame, at: at, session: session)
            loadNext()
        case .window(let session, let window):
            board.apply(window: window, session: session)
            followCapture()
        case .pointer(let session, let pointer):
            board.apply(pointer: pointer, session: session)
            if let chat = board.entries[session]?.chat { push(chat) }
        case .clicked(let session, let click):
            board.apply(click: click, session: session)
            if let chat = board.entries[session]?.chat { push(chat) }
        }
    }

    // MARK: Live view

    /// Streams the window of the running card the person can see, or stops the stream. Runs after
    /// each change that can move it (a push, a window, a change of sight).
    private func followCapture() {
        guard let sight else { return capture.want(nil) }
        let chats = source == nil ? [] : board.liveChats
        sight.follow(chats) { [weak self] in self?.followCapture() }
        capture.want(chats.isEmpty ? nil : board.liveTarget(canSee: sight.canSee))
    }

    /// The agent cursor moved in `session`'s streamed window, or left it (nil).
    private func liveCursor(_ cursor: ComputerUseAgentCursor?, session: String) {
        guard source != nil, board.entries[session] != nil else { return }
        board.apply(cursor: cursor, session: session)
        if let chat = board.entries[session]?.chat { push(chat) }
    }

    /// A live frame of `target`'s window: the card shows it at once.
    private func liveFrame(_ target: ComputerUseLiveCapture.Target, _ frame: ComputerUsePreviewBoard.Frame) {
        guard source != nil, board.entries[target.session] != nil else { return }
        board.loaded(frame, session: target.session)
        if let chat = board.entries[target.session]?.chat { push(chat) }
    }

    // MARK: Frames and apps

    /// Starts the next frame load when none runs; a newer frame waits for the one in flight.
    private func loadNext() {
        guard loading == nil, let next = board.nextLoad(), let source else { return }
        let frame = next.frame
        // task-owner: one frame load at a time; ends with the source's answer (the socket's deadline).
        let task = Task { [weak self] in
            let url = await source.frame(frame.id)
            guard let self, !Task.isCancelled else { return }
            loading = nil
            if let url { board.loaded(.init(id: frame.id, at: frame.at, url: url), session: next.session) } else { board.failed(frame.id, session: next.session) }
            loadNext()
            if url != nil, let chat = board.entries[next.session]?.chat { push(chat) }
        }
        loading = (next.session, frame.id, task)
    }

    /// Looks up the apps the cards name (display name and icon), off the main thread, once per app.
    private func loadApps() {
        let wanted = board.appKeys.subtracting(apps.keys).subtracting(appLoads)
        guard !wanted.isEmpty else { return }
        appLoads.formUnion(wanted)
        let resolver = resolver
        // task-owner: one lookup per app, at most once per launch; results land on the main actor.
        Task { [weak self] in
            for key in wanted {
                let app = await resolver.resolve(key)
                guard let self else { return }
                appLoads.remove(key)
                if apps.count >= Self.maximumApps { apps = apps.filter { board.appKeys.contains($0.key) } }
                apps[key] = .some(app)
            }
            self?.push()
        }
    }

    // MARK: Chats

    /// Gives each routed chat (or only `only`) its card and takes a gone card off. The host passes
    /// on changes only, and a chat whose page was made again gets its card back.
    private func push(_ only: String? = nil) {
        guard let host else { return }
        loadApps()
        let apps = apps.compactMapValues { $0 }
        for chat in only.map({ [$0] }) ?? board.routedChats.union(shown) {
            let card = board.card(for: chat, apps: apps)
            scheduleHide(chat, done: card?.done == true)
            guard card != nil || shown.contains(chat) else { continue }
            if card == nil { shown.remove(chat) } else { shown.insert(chat) }
            host.computerUsePreviewShow(card, in: chat) { [weak self] session, click in self?.respond(session: session, click: click) }
        }
        followCapture()
    }

    /// Starts the hide of chat `chat`'s card when it is done and none waits; stops it when the card
    /// runs again or is gone. A card that stays done keeps its first deadline.
    private func scheduleHide(_ chat: String, done: Bool) {
        guard done else {
            hides.removeValue(forKey: chat)?.cancel()
            return
        }
        guard hides[chat] == nil else { return }
        let timer = DemandTimer(owner: "ComputerUseLivePreview.autoHide", clock: clock)
        hides[chat] = timer
        timer.schedule(after: Self.autoHideDelay) { @MainActor [weak self] in self?.autoHide(chat) }
    }

    /// Chat `chat`'s card stayed done for ``autoHideDelay``: it hides. Unlike the person's close, a
    /// newer action of the same session (the driver keeps it open between turns) shows it again.
    private func autoHide(_ chat: String) {
        hides[chat] = nil
        guard let card = board.card(for: chat), card.done else { return }
        for id in board.autoHide(chat: chat) { source?.follow(session: id, false) }
        push()
    }

    private func respond(session: String, click: ComputerUsePreviewClick) {
        switch click {
        case .open:
            host?.computerUsePreviewOpenActivity(session: session)
        case .close:
            for id in board.dismiss(session: session) { source?.follow(session: id, false) }
            push()
        }
    }
}
