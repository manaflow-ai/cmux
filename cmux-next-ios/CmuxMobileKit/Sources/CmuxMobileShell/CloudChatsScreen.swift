#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxSpinner
import SwiftUI

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
                                        firstPrompt: task?.location == location ? task?.prompt : nil)
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
    /// A New Chat tap made before the relay was ready.
    @State private var startQueue = CloudChatStartQueue()
    /// How many of the machine's chats the list draws, newest first (Show Older Chats adds a page).
    @State private var shown = CloudChatList.pageSize
    /// The last list read failed: keep the last page and offer Retry.
    @State private var listError: String?
    /// Retry and pull to refresh read the list again.
    @State private var listRetry = 0
    @State private var listRequest = 0
    /// nil until this account, team, Mac and machine have returned a valid page.
    @State private var page: CloudChatList.CachedPage?

    init(live: LiveCoordinator?, macID: String, machine: CloudChatMachine, macName: String,
         preferredSession: String?, cachedList: LastKnownList?, firstPrompt: String? = nil) {
        self.live = live
        self.macID = macID
        self.machine = machine
        self.macName = macName
        self.preferredSession = preferredSession
        self.cachedList = cachedList
        self.firstPrompt = firstPrompt
        _page = State(initialValue: cachedList?.read(CloudChatList.CachedPage.self))
    }

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady, let preferredSession, !openedPreferred,
                      relay.hub.listWhole, relay.hub.sessions[preferredSession] == nil {
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
            } else {
                List {
                    if relay?.hub.isReady == true, let cause = listError {
                        Text(cause).foregroundStyle(.secondary)
                        // retry-prompt-ok: a list read that failed on a live link has no automatic redo; reading it is the person's call
                        Button("Retry") { listRetry += 1 }
                    } else if relay?.hub.isReady != true, let cause = failure ?? retryingCause, autoRetry.isQuietLineShown || timedOut {
                        Text(cause).foregroundStyle(.secondary)
                        AutoRetryQuietLine(autoRetry)
                    }
                    if let page {
                        if page.rows.isEmpty {
                            ContentUnavailableView("No chats", systemImage: "bubble.left",
                                                   description: Text("Tap New Chat to start one on this Cloud machine."))
                        }
                        ForEach(page.rows) { row in
                            let current = relay?.hub.sessions[row.id]
                            Button { selectedSession = row.id } label: {
                                VStack(alignment: .leading) {
                                    Text(current?.displayName ?? row.displayName)
                                    if let prompt = current?.lastPrompt ?? row.lastPrompt, !prompt.isEmpty {
                                        Text(prompt).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(relay?.hub.isReady != true || current == nil || current?.peer != nil)
                        }
                        if page.hasOlder {
                            Button("Show Older Chats") { shown += CloudChatList.pageSize }
                                .accessibilityIdentifier("cloudChats.more")
                        }
                    }
                }
                .refreshable {
                    if let hub = relay?.hub, hub.isReady { await readList(hub, settle: false) }
                    else { await connect() }
                }
            }
        }
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
        do {
            let page = try await CloudChatList.newest(hub, shown: shown)
            guard !Task.isCancelled, request == listRequest, hub === relay?.hub else { return }
            let snapshot = CloudChatList.CachedPage(rows: page.sessions(in: hub).map(CloudChatList.CachedRow.init),
                                                    hasOlder: page.hasOlder)
            self.page = snapshot
            listError = nil
            cachedList?.save(snapshot)
        } catch {
            guard !Task.isCancelled, request == listRequest, hub === relay?.hub else { return }
            listError = "Couldn't load chats. Try again."
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
                unsentFirst = session
                sendFirst()
                selectedSession = session
            } catch {
                startError = (error as? CloudChatStartError)?.message ?? "Try again."
                startFailed = true
            }
        }
    }

    /// Sends the first message once the started chat is listed.
    private func sendFirst() {
        guard let session = unsentFirst, let firstPrompt, let store = relay?.store(sessionID: session) else { return }
        unsentFirst = nil
        store.send(prompt: firstPrompt)
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
            } catch {
                startError = (error as? CloudChatStartError)?.message ?? "The Cloud machine didn't start the chat."
                startFailed = true
            }
        }
    }
}
#endif
