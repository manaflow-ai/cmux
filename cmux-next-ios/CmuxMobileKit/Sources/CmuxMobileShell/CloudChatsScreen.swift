#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Native navigation over the paired Mac's Cloud directory. Chat rendering and
/// interaction remain the existing AgentChatScreen and AcpmuxSessionSource.
struct CloudChatsScreen: View {
    let shell: ShellModel
    let attention: CloudChatAttention?
    /// A New Task on a Cloud machine: opens that machine and starts its chat with the task.
    var task: CloudChatTask? = nil
    @State private var selectedMac: String?

    var body: some View {
        let macs = shell.store.activeTeam?.macs ?? []
        let candidates = [task?.location.macID, selectedMac, shell.live?.focusedMacID].compactMap { $0 }
        let macID = candidates.first { id in macs.contains { $0.id == id } } ?? macs.first?.id
        let ids = attention == nil ? macID.map { [$0] } ?? [] : macs.map(\.id).filter {
            shell.live?.canLink(macID: $0) != false
        }
        let scope = CloudDirectoryScope(account: shell.auth.user?.id, team: shell.store.activeTeamID,
                                        macs: ids, attention: attention)
        CloudDirectoryList(shell: shell, scope: scope, macID: macID, task: task, select: { selectedMac = $0 })
            .id(scope)
    }
}

private struct CloudDirectoryScope: Hashable {
    let account: String?
    let team: String
    let macs: [String]
    let attention: CloudChatAttention?
}

/// A source change creates a new list before its first frame. A live refresh keeps the same list.
private struct CloudDirectoryList: View {
    let shell: ShellModel
    let scope: CloudDirectoryScope
    let macID: String?
    let task: CloudChatTask?
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directories: [String: [CloudChatMachine]]
    @State private var selectedLocation: CloudChatLocation?
    /// New Task's chat was started: going back and opening the machine again starts no second one.
    @State private var taskStarted = false
    @State private var failed = false
    @State private var refresh = 0
    /// A failed directory read is read again on its own (no Retry): the spinner stays, and the
    /// failure shows only past the quiet bound, without a button.
    @State private var autoRetry = AutoRetry()
    /// The account's Auto chats, listed first while Settings > Cloud > Auto is on (no Mac needed).
    @State private var auto = AutoChatsPresentation()

    /// The list shows the Auto section: the setting is on, and this is not one chat from a notification.
    private var showsAuto: Bool { scope.attention == nil && shell.settings.cloudAutoMode }

    init(shell: ShellModel, scope: CloudDirectoryScope, macID: String?, task: CloudChatTask? = nil,
         select: @escaping (String) -> Void) {
        self.shell = shell
        self.scope = scope
        self.macID = macID
        self.task = task
        self.select = select
        // New Task named the machine and its Mac: open it at once (its screen connects).
        _selectedLocation = State(initialValue: task?.location)
        let saved = scope.macs.compactMap { id -> (String, [CloudChatMachine])? in
            shell.auth.lastKnownList(screen: "cloud-chats", teamID: scope.team, context: [id])?
                .read([CloudChatMachine].self).map { (id, $0) }
        }
        _directories = State(initialValue: Dictionary(saved, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        let locations = scope.macs.flatMap { id in
            CloudChatDirectory.scopedMachines(directories[id] ?? [], attention: scope.attention)
                .map { CloudChatLocation(macID: id, machine: $0) }
        }
        NavigationStack {
            List {
                if showsAuto { AutoChatsSection(auto: auto) }
                if scope.attention == nil, task == nil, let macs = shell.store.activeTeam?.macs, !macs.isEmpty {
                    Picker("Mac", selection: Binding(get: { macID ?? "" }, set: select)) {
                        ForEach(macs) { mac in Text(mac.name).tag(mac.id) }
                    }
                }
                if !locations.isEmpty {
                    ForEach(locations) { location in
                        Button { selectedLocation = location } label: {
                            Label(location.machine.name, systemImage: "cloud")
                        }
                    }
                } else if !directories.isEmpty {
                    ContentUnavailableView(
                        scope.attention == nil ? "No Cloud machines" : "Chat unavailable",
                        systemImage: "cloud",
                        description: Text(scope.attention == nil
                            ? "Open a Cloud machine on your Mac."
                            : "Choose the Mac connected to this chat’s Cloud machine.")
                    )
                } else if shell.live == nil || scope.macs.isEmpty {
                    CloudChatsConnectMac {
                        shell.cloudChats = nil
                        shell.tab = .settings
                        shell.settingsPath = [.devices]
                    }
                } else if !failed || !autoRetry.isQuietLineShown {
                    // A list that answers within the coming-up bound draws no spinner (Leo, 2026-11-14).
                    // A failed read keeps the wait while `autoRetry` reads again; past the quiet bound
                    // the page says why, with no button.
                    CloudChatsComingUp {
                        // placeholder-ok: none of this account and team's selected Mac directories has answered.
                        CmuxSpinner(label: Text("Loading Cloud chats…"))
                            .placeholderBound("cloud.chats.loading", .milliseconds(2000))
                    }
                }
                if failed, autoRetry.isQuietLineShown {
                    Text("Couldn't load Cloud chats.").foregroundStyle(.secondary)
                    AutoRetryQuietLine(autoRetry)
                }
            }
            .navigationTitle("Cloud chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                }
            }
            .navigationDestination(item: $selectedLocation) { location in
                let name = shell.store.activeTeam?.macs.first { $0.id == location.macID }?.name ?? "your Mac"
                CloudMachineChatsScreen(live: shell.live, macID: location.macID, machine: location.machine,
                                        macName: name, preferredSession: scope.attention?.sessionID,
                                        cachedList: shell.auth.lastKnownList(screen: "cloud-chat-sessions", teamID: scope.team,
                                            context: [location.macID, location.machine.teamID, location.machine.machineID]),
                                        firstPrompt: !taskStarted && task?.location == location ? task?.prompt : nil,
                                        onFirstStarted: { taskStarted = true })
            }
            .modifier(AutoChatsHost(auto: auto, enabled: showsAuto, refresh: refresh) { openCloudMachines() })
            .task(id: Refresh(live: shell.live.map(ObjectIdentifier.init), revision: refresh)) {
                shell.cloudMacID = scope.attention == nil ? macID : nil
                failed = false
                await readScope(retrying: false)
            }
            // A failed read is made again on its own, with backoff, and when the app returns.
            .autoRetry(autoRetry, failing: failed) { await readScope(retrying: true) }
        }
    }

    /// Reads the directory of the selected Mac (or the Macs a push searches). A retry
    /// (`autoRetry`) keeps the failure as it is while it asks, so a Mac still unreachable stays
    /// failed (and is asked again later) instead of blinking.
    private func readScope(retrying: Bool) async {
        guard let live = shell.live else { return }
        if let attention = scope.attention {
            let found = await CloudChatAttentionResolver.find(macIDs: scope.macs, attention: attention) { id in
                try await readDirectory(on: id, live: live, retrying: retrying)
            }
            if !Task.isCancelled, let found { selectedLocation = found }
        } else if let macID {
            _ = try? await readDirectory(on: macID, live: live, retrying: retrying)
        }
    }

    private struct Refresh: Hashable {
        let live: ObjectIdentifier?
        let revision: Int
    }

    /// The existing place to make a Cloud machine: Settings → Cloud Machines.
    private func openCloudMachines() {
        shell.cloudChats = nil
        shell.tab = .settings
        shell.settingsPath = [.cloudMachines]
    }

    /// Capture the account's handle before awaiting the Mac. Only a complete, authenticated reply
    /// replaces this particular Mac's directory, even when a push searched several Macs.
    private func readDirectory(on id: String, live: LiveCoordinator, retrying: Bool = false) async throws -> [CloudChatMachine] {
        guard shell.auth.user?.id == scope.account, shell.store.activeTeamID == scope.team else { throw CancellationError() }
        let cache = shell.auth.lastKnownList(screen: "cloud-chats", teamID: scope.team, context: [id])
        do {
            let machines = try await live.cloudMachines(on: id)
            try Task.checkCancellation()
            guard shell.auth.user?.id == scope.account, shell.store.activeTeamID == scope.team else { throw CancellationError() }
            directories[id] = machines
            if retrying { failed = false }
            cache?.save(machines)
            return machines
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { failed = true }
            throw error
        }
    }
}

/// No Mac to reach Cloud chats through. Cloud chats reach the phone only
/// through a paired online Mac, so the one action opens Settings → Devices,
/// where a Mac is paired (SPEC 7.2, "Workspaces, no Macs").
struct CloudChatsConnectMac: View {
    let connect: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Connect your Mac", systemImage: "desktopcomputer")
        } description: {
            Text("Cloud chats open through a Mac signed in to this account.")
        } actions: {
            PrimaryCapsule("Connect a Mac", size: .inline, action: connect)
                .accessibilityIdentifier("cloudChats.connectMac")
        }
    }
}

/// A Cloud list's or machine's wait, drawn only once it has lasted ``QuietStatusGate/threshold``
/// (the shared 10 s `connectionQuietMs` of schemas/notice-timing): a connect that answers inside it
/// goes straight from nothing to the list (Leo, 2026-11-14: "i also want all our connectivity stuff
/// to shut up and load faster/percievably load faster"). A failure, which has Retry, never waits:
/// it is its own view. One gate per wait, ended with the view. Only with Settings → Transport →
/// Quiet Cloud Connections on (off by default); off draws the wait at once, as before.
struct CloudChatsComingUp<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var gate = QuietStatusGate()
    @AppStorage(CmuxMobilePreferences.Key.quietCloudConnect) private var quiet = CmuxMobilePreferences.defaultQuietCloudConnect

    var body: some View {
        Group {
            if !quiet || gate.isShown { content() } else { Color.clear.frame(height: 1).accessibilityHidden(true) }
        }
        .onAppear { gate.update(down: true) }
        .onDisappear { gate.update(down: false) }
    }
}

/// How long the phone waits for a Cloud machine's chats before it says why it
/// stopped: the paired link's 20 s (`cloudLink`) plus the chat channel's first
/// request (`AcpmuxHub.bind`, 20 s).
let cloudConnectBudget: Duration = .seconds(40)

/// The wait for a Cloud machine's chats draws nothing: no spinner, no "Connecting to <machine>
/// through <Mac>…" and no count of seconds. The phone keeps connecting and the chats fill in
/// when the machine answers (Leo, 2026-11-24: "all the connecting... indicators ... nah let's
/// not do that. let's just keep optimistically connecting and reinforcing the connection").
/// Past `cloudConnectBudget` the screen says why it stopped, with the quiet line (`CloudChatsConnectFailed`).
struct CloudChatsConnecting: View {
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The connect failed or ran past `cloudConnectBudget`: the cause, and the quiet line while
/// `autoRetry` connects again on its own (no Retry: reconnecting has only one answer).
struct CloudChatsConnectFailed: View {
    let cause: String
    let autoRetry: AutoRetry

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't connect", systemImage: "cloud")
        } description: {
            Text(cause)
        } actions: { AutoRetryQuietLine(autoRetry) }
        .accessibilityIdentifier("cloudChats.connectFailed")
    }
}

/// What the Cloud chat list's read depends on.
private struct ListRead: Equatable {
    let ready: Bool
    let revision: Int
    let shown: Int
    let retry: Int
}

/// New Chat on a Cloud machine is tappable while its relay connects: a tap before the hub is
/// ready waits for it and starts the chat then, instead of a grayed, dead button (Leo, 2026-11-24,
/// back from another app: "the entire thing is somehow grayed out and I can't interact with
/// anything at all"). A connect that fails drops the waiting tap, and the person is told why.
struct CloudChatStartQueue: Equatable {
    /// A New Chat tap waits for the hub.
    private(set) var queued = false

    enum Step: Equatable {
        /// Start the chat now.
        case start
        /// Nothing to do (waiting, or a start already runs).
        case none
        /// The waiting tap was dropped: the connect failed.
        case dropped
    }

    /// New Chat tapped: start now when the hub is ready, else wait for it. A second tap while one
    /// starts or waits is the same request.
    mutating func tap(ready: Bool, starting: Bool) -> Step {
        if starting || queued { return .none }
        if ready { return .start }
        queued = true
        return .none
    }

    /// The link changed: a waiting tap starts once the hub is ready, and is dropped if the connect failed.
    mutating func link(ready: Bool, failed: Bool) -> Step {
        guard queued else { return .none }
        if ready {
            queued = false
            return .start
        }
        if failed {
            queued = false
            return .dropped
        }
        return .none
    }
}

private struct CloudMachineChatsScreen: View {
    let live: LiveCoordinator?
    let macID: String
    let machine: CloudChatMachine
    let macName: String
    let preferredSession: String?
    private let cachedList: LastKnownList?
    /// New Task's prompt: once connected, a new chat starts and this is its first message.
    private let firstPrompt: String?
    /// The first message's chat was started (a reconnect never starts a second).
    @State private var startedFirst = false
    /// The started chat the first message waits on: the machine lists a new chat after it answers.
    @State private var unsentFirst: String?
    /// The first message, kept once its chat started (the list then passes no `firstPrompt`).
    @State private var unsentPrompt: String?
    /// Tells the list New Task's chat started, so opening this machine again starts no second chat.
    private let onFirstStarted: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var relay: CloudChatRelay?
    @State private var selectedSession: String?
    @State private var error: String?
    /// The relay was not ready within `cloudConnectBudget`.
    @State private var timedOut = false
    /// The cause shown while a retry asks again, so the page does not blink back to the wait.
    @State private var retryingCause: String?
    /// A failed connect is made again on its own (no Retry or Reconnect): the wait stays through a
    /// short failure; past the quiet bound the page says why, with no button.
    @State private var autoRetry = AutoRetry()
    @State private var openedPreferred = false
    @State private var starting = false
    @State private var startFailed = false
    @State private var startError = ""
    /// The last start was refused for want of GitHub on the machine: its Sign in with GitHub card.
    @State private var gitHubNeed: GitHubSignInNeed?
    /// A New Chat tap made before the relay was ready.
    @State private var startQueue = CloudChatStartQueue()
    /// How many of the machine's chats the list draws, newest first (a page more as the reader nears
    /// the end, on the shared ``PagedList``). Kept over a reconnect.
    @State private var shown = CloudChatList.pageSize
    /// The `shown` the drawn page was read for: below `shown`, a page more is on its way.
    @State private var pageShown = 0
    /// The last list read failed: keep the last page and offer Retry.
    @State private var listError: String?
    /// The last read of a page more failed: the list's end offers Try Again.
    @State private var moreError: String?
    /// Retry and pull to refresh read the list again.
    @State private var listRetry = 0
    @State private var listRequest = 0
    /// nil until this account, team, Mac and machine have returned a valid page.
    @State private var page: CloudChatList.CachedPage?

    init(live: LiveCoordinator?, macID: String, machine: CloudChatMachine, macName: String,
         preferredSession: String?, cachedList: LastKnownList?, firstPrompt: String? = nil,
         onFirstStarted: @escaping () -> Void = {}) {
        self.live = live
        self.macID = macID
        self.machine = machine
        self.macName = macName
        self.preferredSession = preferredSession
        self.cachedList = cachedList
        self.firstPrompt = firstPrompt
        self.onFirstStarted = onFirstStarted
        let cached = cachedList?.read(CloudChatList.CachedPage.self)
        _page = State(initialValue: cached)
        _pageShown = State(initialValue: cached?.rows.count ?? 0)
    }

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady,
                      CloudChatList.preferredUnavailable(preferredSession, sessions: relay.hub.sessions,
                                                         listWhole: relay.hub.listWhole, opened: openedPreferred) {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                       description: Text("This chat is no longer listed on this Cloud machine."))
            } else if page == nil, relay?.hub.isReady != true, let cause = failure ?? retryingCause {
                if autoRetry.isQuietLineShown || timedOut {
                    // A short failure keeps the wait (`autoRetry` connects again); a full
                    // `cloudConnectBudget` with no answer says so at once.
                    CloudChatsConnectFailed(cause: cause, autoRetry: autoRetry)
                } else {
                    CloudChatsConnecting()
                }
            } else if let page {
                // The chats on the shared infinite-scroll list: a page more is read as the reader
                // nears the end (no Show Older Chats button), and a page that lands never moves
                // the row being read.
                let ready = relay?.hub.isReady == true
                let state = CloudChatsListState(
                    rows: page.rows.map { CloudChatsListItem($0, current: relay?.hub.sessions[$0.id], ready: ready) },
                    hasOlder: page.hasOlder, pageShown: pageShown, shown: shown, failure: moreError)
                CloudMachineChatsList(state: state, shown: $shown, select: { selectedSession = $0 },
                                      retry: { moreError = nil; listRetry += 1 }, refresh: { await refreshList() })
                    .safeAreaInset(edge: .top, spacing: 0) { notices(listErrorOnTop: !state.readsOlder) }
            } else {
                // Nothing read yet for this machine: what to say, if anything, and no rows.
                List {
                    if let need = gitHubNeed {
                        gitHubCard(need)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                    if let line = topLine(listErrorOnTop: true) { topLineViews(line) }
                }
                .refreshable { await refreshList() }
            }
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { newChatTapped() }
                    .disabled(starting)
                    .accessibilityIdentifier("cloudChats.new")
            }
        }
        .alert("Couldn't start the chat", isPresented: $startFailed) {
            if firstPrompt != nil, !startedFirst {
                Button("Try Again") { startFirst() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(startError)
        }
        .navigationDestination(item: $selectedSession) { sessionID in
            if let store = relay?.store(sessionID: sessionID) {
                AgentChatScreen(store: store)
            } else {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            }
        }
        .task { await connect() }
        .autoRetry(autoRetry, failing: relay?.hub.isReady != true && (failure ?? retryingCause) != nil) { await connect() }
        // acpmux orders and picks the page; a change of the hub's list reads it again (the last
        // page stays drawn meanwhile, and after a failed read until the next change).
        .task(id: ListRead(ready: relay?.hub.isReady == true, revision: relay?.hub.listRevision ?? 0,
                           shown: shown, retry: listRetry)) {
            guard let hub = relay?.hub, hub.isReady else { return }
            await readList(hub, settle: page != nil)
        }
        // placeholder-ok: a New Chat the user tapped is starting; there is no chat to show yet.
        .overlay { if starting || startQueue.queued { CmuxSpinner(label: Text("Starting chat…")) } }
        // A New Chat tap made while the relay connected starts once it is ready.
        .onChange(of: [relay?.hub.isReady == true, failure != nil || relay?.isRetired == true]) { _, link in
            switch startQueue.link(ready: link[0], failed: link[1]) {
            case .start: startChat()
            case .dropped:
                startError = failure ?? "This Cloud machine's chats are unavailable."
                startFailed = true
            case .none: break
            }
        }
        // New Task's chat starts once the machine is connected.
        .onChange(of: relay?.hub.isReady == true, initial: true) { _, ready in
            if ready { startFirst() }
        }
        .onChange(of: unsentFirst.flatMap { relay?.hub.sessions[$0] } != nil) { _, listed in
            if listed { sendFirst() }
        }
        // Wake on intent: the app became active (the phone unlocked) with this machine's chats in
        // front, so a paused machine starts waking before the first key (`CloudWakeOnIntent`).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await CloudWakeOnIntent.shared.hint(machine, signal: "unlock") }
        }
        // The preferred chat opens once it is listed: with the first page, or with a later one.
        .onChange(of: relay?.hub.isReady == true && preferredSession.flatMap { relay?.hub.sessions[$0] } != nil, initial: true) { _, ready in
            guard ready, !openedPreferred, let preferredSession,
                  relay?.hub.sessions[preferredSession]?.peer == nil,
                  relay?.hub.sessions[preferredSession] != nil else { return }
            openedPreferred = true
            selectedSession = preferredSession
        }
    }

    /// Opens the machine's chats through the Mac and waits for them, at most `cloudConnectBudget`
    /// from the start. A retry keeps the last cause on screen until this attempt answers.
    private func connect() async {
        retryingCause = failure
        defer { retryingCause = nil }
        let started = ContinuousClock.now
        guard let live else { error = "Connect your Mac."; return }
        do {
            let opened = try await live.cloudChats(on: macID, machine: machine)
            relay = opened
            // `relay.error` is cleared as the bind starts and set when it fails, so this answers at
            // the first ready or failed bind (a stale `hub.lastError` is not read here).
            let left = max(.zero, cloudConnectBudget - (ContinuousClock.now - started))
            let ready = await ObservationWait({ opened.hub.isReady || opened.error != nil }, budget: left).value
            guard !Task.isCancelled else { return }
            error = nil
            timedOut = !ready && opened.error == nil
        } catch {
            guard !Task.isCancelled else { return }
            timedOut = false
            self.error = "Couldn't connect."
        }
    }

    /// Reads the first `shown` chats. A failed read keeps the last page visible and offers Retry.
    private func readList(_ hub: AcpmuxHub, settle: Bool) async {
        listRequest += 1
        let request = listRequest
        if settle { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled, request == listRequest, hub === relay?.hub else { return }
        let asked = shown
        do {
            let page = try await CloudChatList.newest(hub, shown: asked)
            guard !Task.isCancelled, request == listRequest, hub === relay?.hub else { return }
            let snapshot = CloudChatList.CachedPage(rows: page.sessions(in: hub).map(CloudChatList.CachedRow.init),
                                                    hasOlder: page.hasOlder)
            self.page = snapshot
            pageShown = asked
            listError = nil
            moreError = nil
            cachedList?.save(snapshot)
        } catch {
            guard !Task.isCancelled, request == listRequest, hub === relay?.hub else { return }
            // A page more that failed says so at the list's end (Try Again); a failed read of the
            // chats drawn says so over them.
            if self.page?.hasOlder == true, asked > pageShown {
                moreError = "Couldn't load older chats."
            } else {
                listError = "Couldn't load chats. Try again."
            }
        }
    }

    /// Pull to refresh: the list read again on a live link, else the machine connected again.
    private func refreshList() async {
        if let hub = relay?.hub, hub.isReady { await readList(hub, settle: false) }
        else { await connect() }
    }

    /// What shows over the chats, if anything: New Chat's Sign in with GitHub card, then a failed
    /// read of the list (a failed page more is the end's instead) or a connect failure past the quiet bound.
    @ViewBuilder private func notices(listErrorOnTop: Bool) -> some View {
        let line = topLine(listErrorOnTop: listErrorOnTop)
        if gitHubNeed != nil || line != nil {
            VStack(spacing: 8) {
                if let need = gitHubNeed { gitHubCard(need) }
                if let line { topLineViews(line) }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.colors.bg.color)
        }
    }

    /// The line over the chats: a failed list read on a live link, or why the connect stopped.
    private enum TopLine: Equatable {
        case listFailed(String)
        case connectFailed(String)
    }

    private func topLine(listErrorOnTop: Bool) -> TopLine? {
        if relay?.hub.isReady == true {
            return listErrorOnTop ? listError.map(TopLine.listFailed) : nil
        }
        guard let cause = failure ?? retryingCause, autoRetry.isQuietLineShown || timedOut else { return nil }
        return .connectFailed(cause)
    }

    @ViewBuilder private func topLineViews(_ line: TopLine) -> some View {
        switch line {
        case let .listFailed(cause):
            Text(cause).foregroundStyle(.secondary)
            // retry-prompt-ok: a list read that failed on a live link has no automatic redo; reading it is the person's call
            Button("Retry") { listRetry += 1 }
        case let .connectFailed(cause):
            Text(cause).foregroundStyle(.secondary)
            AutoRetryQuietLine(autoRetry)
        }
    }

    /// Back from GitHub, the start runs again.
    private func gitHubCard(_ need: GitHubSignInNeed) -> some View {
        GitHubSignInCard(need: need) {
            gitHubNeed = nil
            // New Task's chat keeps its first prompt through the sign-in.
            if firstPrompt != nil, !startedFirst { startFirst() } else { startChat() }
        }
    }

    /// Why the connect stopped, naming the step that did not answer; nil while it may still finish.
    private var failure: String? {
        if error != nil { return "\(macName) didn't reach \(machine.name). Check that the Mac is awake and online." }
        if relay?.error != nil || relay?.hub.lastError != nil { return "\(machine.name) didn't open its chats through \(macName)." }
        if timedOut { return "No answer from \(machine.name) through \(macName) in \(cloudConnectBudget.components.seconds) s." }
        return nil
    }

    /// New Task's chat: started once, its prompt sent as the first message, then opened. A
    /// failed start keeps the prompt here for Try Again.
    private func startFirst() {
        guard firstPrompt != nil, !startedFirst, let relay, relay.hub.isReady, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let session = try await relay.startChat()
                startedFirst = true
                unsentPrompt = firstPrompt
                unsentFirst = session
                onFirstStarted()
                sendFirst()
                selectedSession = session
                gitHubNeed = nil
            } catch {
                // Same Sign in with GitHub card as a plain New Chat start.
                if let need = (error as? CloudChatStartError)?.github {
                    gitHubNeed = need
                    return
                }
                startError = (error as? CloudChatStartError)?.message ?? "Try again."
                startFailed = true
            }
        }
    }

    /// Sends the first message once the started chat is listed.
    private func sendFirst() {
        guard let session = unsentFirst, let prompt = unsentPrompt, let store = relay?.store(sessionID: session) else { return }
        unsentFirst = nil
        unsentPrompt = nil
        store.send(prompt: prompt)
    }

    private func newChatTapped() {
        if startQueue.tap(ready: relay?.hub.isReady == true, starting: starting) == .start { startChat() }
    }

    /// The new chat opens as soon as the machine started it; the Mac shows the same tab.
    private func startChat() {
        guard let relay, relay.hub.isReady, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                selectedSession = try await relay.startChat()
                gitHubNeed = nil
            } catch {
                // No GitHub access on the machine: one Sign in with GitHub card, not an alert.
                if let need = (error as? CloudChatStartError)?.github {
                    gitHubNeed = need
                    return
                }
                startError = (error as? CloudChatStartError)?.message ?? "The Cloud machine didn't start the chat."
                startFailed = true
            }
        }
    }
}

/// A Cloud machine's chats on the shared infinite-scroll list (``PagedList``, verify/paged-list.md),
/// in acpmux's order: a page more is read as the reader nears the end (no Show Older Chats button),
/// and rows that land or move never shift the row being read. While a page more is read the end
/// spins; if that read failed, the end offers Try Again. Apart from the screen, so its DEBUG gallery
/// (``CloudChatsGallery``) draws the same view on fixed chats.
struct CloudMachineChatsList: View {
    let rows: [CloudChatsListItem]
    let edge: PagedListEdge
    let hasOlder: Bool
    /// How many chats show; a page more when the reader nears the end.
    @Binding var shown: Int
    /// The `shown` this list was drawn with: the list asks on every scroll step near the end, and
    /// one drawn list adds one page.
    let drawnShown: Int
    let select: @MainActor (String) -> Void
    /// The end's Try Again: the page more is read again.
    let retry: @MainActor () -> Void
    /// Pull to refresh (nil: none).
    var refresh: (@MainActor () async -> Void)?
    var probe: PagedListProbe?

    init(state: CloudChatsListState, shown: Binding<Int>, select: @escaping @MainActor (String) -> Void,
         retry: @escaping @MainActor () -> Void, refresh: (@MainActor () async -> Void)? = nil,
         probe: PagedListProbe? = nil) {
        rows = state.rows
        edge = state.edge
        hasOlder = state.hasOlder
        _shown = shown
        drawnShown = shown.wrappedValue
        self.select = select
        self.retry = retry
        self.refresh = refresh
        self.probe = probe
    }

    var body: some View {
        let list = PagedList(direction: .down, items: rows, phase: .loaded, edge: edge,
                             loadMore: { showMore() }, retry: { retry() }) { item in
            Button { select(item.id) } label: {
                CloudChatRow(item: item)
            }
            .buttonStyle(.cmuxPressFill)
            .disabled(!item.openable)
            .accessibilityIdentifier("cloudChats.row.\(item.id)")
        } empty: {
            ContentUnavailableView("No chats", systemImage: "bubble.left",
                                   description: Text("Tap New Chat to start one on this Cloud machine."))
        }
        .pagedIdentifier("cloudChats.list")
        .pagedProbe(probe)
        if let refresh { list.pagedRefresh(refresh) } else { list }
    }
}

/// The adapter between a Cloud machine's chats and their list: the chats drawn (the page acpmux
/// sent for `pageShown`), whether older ones follow, whether a page more is on its way, and the
/// list's edge. The screen makes it from its acpmux page, the gallery from fixed chats.
struct CloudChatsListState: Equatable {
    let rows: [CloudChatsListItem]
    let hasOlder: Bool
    /// A page more was asked for (`shown` past `pageShown`) and has not landed: its read runs, or failed.
    let readsOlder: Bool
    let edge: PagedListEdge

    init(rows: [CloudChatsListItem], hasOlder: Bool, pageShown: Int, shown: Int, failure: String?) {
        self.rows = rows
        self.hasOlder = hasOlder
        readsOlder = hasOlder && shown > pageShown
        edge = CloudChatList.edge(hasOlder: hasOlder, readingMore: readsOlder, failure: failure)
    }
}

extension CloudMachineChatsList {
    /// One page more of the chats, once per drawn list.
    func showMore() {
        let next = drawnShown + CloudChatList.pageSize
        if hasOlder, shown < next { shown = next }
    }
}

/// One Cloud chat as its row draws it (the row's height is cached per value).
struct CloudChatsListItem: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String?
    /// A tap opens the chat: the link is live and the hub lists it as this machine's own.
    let openable: Bool

    init(id: String, title: String, prompt: String?, openable: Bool = true) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.openable = openable
    }

    /// A row of acpmux's page, as the hub knows the chat now (the watch keeps it current), else as
    /// the page sent it.
    init(_ row: CloudChatList.CachedRow, current: AcpmuxSession?, ready: Bool) {
        self.init(id: row.id, title: current?.displayName ?? row.displayName,
                  prompt: (current?.lastPrompt ?? row.lastPrompt).flatMap { $0.isEmpty ? nil : $0 },
                  openable: ready && current != nil && current?.peer == nil)
    }
}

struct CloudChatRow: View {
    let item: CloudChatsListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label.color)
            if let prompt = item.prompt {
                Text(prompt)
                    .font(theme.type.rowSubtitle)
                    .foregroundStyle(theme.colors.label2.color)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 1 / 3).padding(.leading, 16)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
