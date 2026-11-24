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
    @State private var selectedMac: String?

    var body: some View {
        let macs = shell.store.activeTeam?.macs ?? []
        let candidates = [selectedMac, shell.live?.focusedMacID].compactMap { $0 }
        let macID = candidates.first { id in macs.contains { $0.id == id } } ?? macs.first?.id
        let ids = attention == nil ? macID.map { [$0] } ?? [] : macs.map(\.id).filter {
            shell.live?.canLink(macID: $0) != false
        }
        let scope = CloudDirectoryScope(account: shell.auth.user?.id, team: shell.store.activeTeamID,
                                        macs: ids, attention: attention)
        CloudDirectoryList(shell: shell, scope: scope, macID: macID, select: { selectedMac = $0 })
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
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directories: [String: [CloudChatMachine]]
    @State private var selectedLocation: CloudChatLocation?
    @State private var failed = false
    @State private var refresh = 0

    init(shell: ShellModel, scope: CloudDirectoryScope, macID: String?, select: @escaping (String) -> Void) {
        self.shell = shell
        self.scope = scope
        self.macID = macID
        self.select = select
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
                if scope.attention == nil, let macs = shell.store.activeTeam?.macs, !macs.isEmpty {
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
                } else if !failed {
                    // placeholder-ok: none of this account and team's selected Mac directories has answered.
                    CmuxSpinner(label: Text("Loading Cloud chats…"))
                }
                if failed {
                    Text("Couldn't load Cloud chats. Try again.").foregroundStyle(.secondary)
                    Button("Retry") { refresh += 1 }
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
                                            context: [location.macID, location.machine.teamID, location.machine.machineID]))
            }
            .task(id: Refresh(live: shell.live.map(ObjectIdentifier.init), revision: refresh)) {
                shell.cloudMacID = scope.attention == nil ? macID : nil
                failed = false
                guard let live = shell.live else { return }
                if let attention = scope.attention {
                    let found = await CloudChatAttentionResolver.find(macIDs: scope.macs, attention: attention) { id in
                        try await readDirectory(on: id, live: live)
                    }
                    if !Task.isCancelled, let found { selectedLocation = found }
                } else if let macID {
                    _ = try? await readDirectory(on: macID, live: live)
                }
            }
        }
    }

    private struct Refresh: Hashable {
        let live: ObjectIdentifier?
        let revision: Int
    }

    /// Capture the account's handle before awaiting the Mac. Only a complete, authenticated reply
    /// replaces this particular Mac's directory, even when a push searched several Macs.
    private func readDirectory(on id: String, live: LiveCoordinator) async throws -> [CloudChatMachine] {
        guard shell.auth.user?.id == scope.account, shell.store.activeTeamID == scope.team else { throw CancellationError() }
        let cache = shell.auth.lastKnownList(screen: "cloud-chats", teamID: scope.team, context: [id])
        do {
            let machines = try await live.cloudMachines(on: id)
            try Task.checkCancellation()
            guard shell.auth.user?.id == scope.account, shell.store.activeTeamID == scope.team else { throw CancellationError() }
            directories[id] = machines
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

/// How long the phone waits for a Cloud machine's chats before it says why it
/// stopped: the paired link's 20 s (`cloudLink`) plus the chat channel's first
/// request (`AcpmuxHub.bind`, 20 s).
let cloudConnectBudget: Duration = .seconds(40)

/// The wait for a Cloud machine's chats: what it waits on (the machine, through
/// which Mac) and how long it can take, counted up once past 5 s (SPEC 6, "Working · 12s").
struct CloudChatsConnecting: View {
    let machine: String
    let mac: String
    let since: Date

    var body: some View {
        let quiet = Int(QuietStatusGate.threshold.components.seconds)
        TimelineView(ElapsedTextSchedule(since: since, quietSeconds: quiet)) { context in
            let elapsed = Int(context.date.timeIntervalSince(since))
            if elapsed >= quiet {
                VStack(spacing: 2) {
                    Text("Connecting to \(machine) through \(mac)…")
                    Text("\(elapsed)s elapsed, up to \(cloudConnectBudget.components.seconds)s")
                        .foregroundStyle(.tertiary)
                }
                .font(CmuxMobileTheme.standard.type.meta)
                .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cloudChats.connecting")
    }
}

/// The connect failed or ran past `cloudConnectBudget`: the cause, then Retry.
struct CloudChatsConnectFailed: View {
    let cause: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't connect", systemImage: "cloud")
        } description: {
            Text(cause)
        } actions: { RetryButton { retry() } }
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
    @State private var relay: CloudChatRelay?
    @State private var selectedSession: String?
    @State private var error: String?
    @State private var refresh = 0
    @State private var connectingSince = Date.now
    /// The relay was not ready within `cloudConnectBudget`.
    @State private var timedOut = false
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
         preferredSession: String?, cachedList: LastKnownList?) {
        self.live = live
        self.macID = macID
        self.machine = machine
        self.macName = macName
        self.preferredSession = preferredSession
        self.cachedList = cachedList
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
            } else if page == nil, relay?.hub.isReady != true, let cause = failure {
                CloudChatsConnectFailed(cause: cause) { refresh += 1 }
            } else {
                List {
                    if let cause = relay?.hub.isReady == true ? listError : failure {
                        Text(cause).foregroundStyle(.secondary)
                        Button("Retry") {
                            if relay?.hub.isReady == true { listRetry += 1 } else { refresh += 1 }
                        }
                    } else if relay?.hub.isReady != true {
                        // placeholder-ok: the connection line is quiet until the delay and leaves cached rows visible.
                        CloudChatsConnecting(machine: machine.name, mac: macName, since: connectingSince)
                            .listRowSeparator(.hidden)
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
                    else { refresh += 1 }
                }
            }
        }
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") { refresh += 1 }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { newChatTapped() }
                    .disabled(starting)
                    .accessibilityIdentifier("cloudChats.new")
            }
        }
        .alert("Couldn't start the chat", isPresented: $startFailed) {
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
        .task(id: refresh) {
            timedOut = false
            connectingSince = .now
            try? await Task.sleep(for: cloudConnectBudget)
            guard !Task.isCancelled, relay?.hub.isReady != true else { return }
            timedOut = true
        }
        .task(id: refresh) {
            error = nil
            do {
                guard let live else { error = "Connect your Mac."; return }
                relay = try await live.cloudChats(on: macID, machine: machine)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Couldn't connect. Try again."
            }
        }
        // acpmux orders and picks the page; a change of the hub's list reads it again (the last
        // page stays drawn meanwhile, and after a failed read until the next change).
        .task(id: ListRead(ready: relay?.hub.isReady == true, revision: relay?.hub.listRevision ?? 0,
                           shown: shown, retry: listRetry)) {
            guard let hub = relay?.hub, hub.isReady else { return }
            await readList(hub, settle: page != nil)
        }
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
        // The preferred chat opens once it is listed: with the first page, or with a later one.
        .onChange(of: relay?.hub.isReady == true && preferredSession.flatMap { relay?.hub.sessions[$0] } != nil, initial: true) { _, ready in
            guard ready, !openedPreferred, let preferredSession,
                  relay?.hub.sessions[preferredSession]?.peer == nil,
                  relay?.hub.sessions[preferredSession] != nil else { return }
            openedPreferred = true
            selectedSession = preferredSession
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
                startError = (error as? CloudChatStartError)?.message ?? "Try again."
                startFailed = true
            }
        }
    }
}
#endif
