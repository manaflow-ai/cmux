#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileLive
import CmuxMobileNotifications
import CmuxSpinner
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Native navigation over the paired Mac's Cloud directory. Chat rendering and
/// interaction remain the existing AgentChatScreen and AcpmuxSessionSource.
struct CloudChatsScreen: View {
    let shell: ShellModel
    let attention: CloudChatAttention?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMac = ""
    @State private var locations: [CloudChatLocation] = []
    @State private var selectedLocation: CloudChatLocation?
    @State private var loading = false
    @State private var error: String?
    /// No Mac to read Cloud chats through: the state offers Connect a Mac, not Retry.
    @State private var needsMac = false
    @State private var refresh = 0

    private var macID: String {
        selectedMac.isEmpty ? shell.live?.focusedMacID ?? shell.store.activeTeam?.macs.first?.id ?? "" : selectedMac
    }

    private var eligibleMacIDs: [String] {
        guard let live = shell.live else { return [] }
        return shell.store.activeTeam?.macs.map(\.id).filter { live.canLink(macID: $0) } ?? []
    }

    private struct Load: Hashable {
        let mac: String
        let macs: [String]
        let live: ObjectIdentifier?
        let team: String
        let refresh: Int
    }

    var body: some View {
        NavigationStack {
            List {
                if attention == nil, let macs = shell.store.activeTeam?.macs, !macs.isEmpty {
                    Picker("Mac", selection: Binding(get: { macID }, set: { selectedMac = $0 })) {
                        ForEach(macs) { mac in Text(mac.name).tag(mac.id) }
                    }
                }
                if loading {
                    CmuxSpinner(label: Text("Loading Cloud chats…"))
                } else if needsMac {
                    CloudChatsConnectMac { openDevices() }
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { refresh += 1 }
                } else if locations.isEmpty {
                    ContentUnavailableView(
                        attention == nil ? "No Cloud machines" : "Chat unavailable",
                        systemImage: "cloud",
                        description: Text(attention == nil
                            ? "Open a Cloud machine on your Mac."
                            : "Choose the Mac connected to this chat’s Cloud machine.")
                    )
                } else {
                    ForEach(locations) { location in
                        Button { selectedLocation = location } label: {
                            Label(location.machine.name, systemImage: "cloud")
                        }
                    }
                }
            }
            .navigationTitle("Cloud chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }
                        .disabled(loading)
                }
            }
            .navigationDestination(item: $selectedLocation) { location in
                CloudMachineChatsScreen(live: shell.live, macID: location.macID, machine: location.machine,
                                        macName: macName(location.macID), preferredSession: attention?.sessionID)
            }
            .task(id: Load(mac: attention == nil ? macID : "", macs: eligibleMacIDs.sorted(),
                           live: shell.live.map(ObjectIdentifier.init), team: shell.store.activeTeamID, refresh: refresh)) {
                shell.cloudMacID = attention == nil && !macID.isEmpty ? macID : nil
                selectedLocation = nil
                locations = []
                error = nil
                needsMac = false
                guard let live = shell.live, attention != nil ? !eligibleMacIDs.isEmpty : !macID.isEmpty else {
                    loading = false
                    needsMac = true
                    return
                }
                loading = true
                do {
                    let found: [CloudChatLocation]
                    if let attention {
                        // Push routing is pinned to an exact authenticated
                        // Cloud team/machine, even when another Mac is focused.
                        let match = await CloudChatAttentionResolver.find(macIDs: eligibleMacIDs, attention: attention) { id in
                            try await live.cloudMachines(on: id)
                        }
                        found = match.map { [$0] } ?? []
                    } else {
                        let listed = try await live.cloudMachines(on: macID)
                        found = CloudChatDirectory.scopedMachines(listed, attention: nil)
                            .map { CloudChatLocation(macID: macID, machine: $0) }
                    }
                    try Task.checkCancellation()
                    locations = found
                    loading = false
                    if attention != nil, found.count == 1 { selectedLocation = found[0] }
                } catch {
                    guard !Task.isCancelled else { return }
                    loading = false
                    self.error = "Couldn't load Cloud chats. Try again."
                }
            }
        }
    }

    private func macName(_ id: String) -> String {
        shell.store.teams.flatMap(\.macs).first { $0.id == id }?.name ?? "your Mac"
    }

    /// The existing place to pair a Mac: Settings → Devices (its Macs and Scan QR on your Mac).
    private func openDevices() {
        shell.cloudChats = nil
        shell.tab = .settings
        shell.settingsPath = [.devices]
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
        VStack(spacing: 6) {
            CmuxSpinner(label: Text("Connecting to \(machine) through \(mac)…"))
            // The text is "Up to 40 s" for the first 5 s: no redraw until it counts.
            TimelineView(ElapsedTextSchedule(since: since, quietSeconds: 5)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since))
                Text(elapsed < 5 ? "Up to \(cloudConnectBudget.components.seconds) s"
                                 : "\(elapsed) s · up to \(cloudConnectBudget.components.seconds) s")
                    .font(CmuxMobileTheme.standard.type.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
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

private struct CloudMachineChatsScreen: View {
    let live: LiveCoordinator?
    let macID: String
    let machine: CloudChatMachine
    let macName: String
    let preferredSession: String?
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
    /// How many of the machine's chats the list draws, newest first (a page more as the reader nears
    /// the end). Kept over a reconnect, so Try Again at the end comes back to the same rows.
    @State private var shown = CloudChatList.pageSize

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady {
                if CloudChatList.preferredUnavailable(preferredSession, sessions: relay.hub.sessions,
                                                      listWhole: relay.hub.listWhole, opened: openedPreferred) {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This chat is no longer listed on this Cloud machine."))
                } else {
                    CloudMachineChatsList(state: CloudChatsListState(hub: relay.hub, shown: shown), shown: $shown,
                                          select: { selectedSession = $0 }, reconnect: { refresh += 1 })
                }
            } else if let cause = failure {
                CloudChatsConnectFailed(cause: cause) { refresh += 1 }
            } else {
                CloudChatsConnecting(machine: machine.name, mac: macName, since: connectingSince)
            }
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") { refresh += 1 }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { startChat() }
                    .disabled(starting || relay?.hub.isReady != true)
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
        .overlay { if starting { CmuxSpinner(label: Text("Starting chat…")) } }
        // The preferred chat opens once it is listed: with the first page, or with a later one.
        .onChange(of: relay?.hub.isReady == true && preferredSession.flatMap { relay?.hub.sessions[$0] } != nil, initial: true) { _, ready in
            guard ready, !openedPreferred, let preferredSession,
                  relay?.hub.sessions[preferredSession]?.peer == nil,
                  relay?.hub.sessions[preferredSession] != nil else { return }
            openedPreferred = true
            selectedSession = preferredSession
        }
    }

    /// Why the connect stopped, naming the step that did not answer; nil while it may still finish.
    private var failure: String? {
        if error != nil { return "\(macName) didn't reach \(machine.name). Check that the Mac is awake and online." }
        if relay?.error != nil || relay?.hub.lastError != nil { return "\(machine.name) didn't open its chats through \(macName)." }
        if timedOut { return "No answer from \(machine.name) through \(macName) in \(cloudConnectBudget.components.seconds) s." }
        return nil
    }

    /// The new chat opens as soon as the machine started it; the Mac shows the same tab.
    private func startChat() {
        guard let relay, !starting else { return }
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

/// A Cloud machine's chats on the shared infinite-scroll list (``PagedList``, verify/paged-list.md),
/// newest first: a page more of the chats the hub holds shows as the reader nears the end (no Show
/// Older Chats button), and rows that land or move never shift the row being read. While the hub
/// still reads the machine's older chats the end spins; if that read stopped short, the end offers
/// Try Again (a reconnect). Apart from the screen, so its DEBUG gallery (``CloudChatsGallery``) draws
/// the same view on fixed chats.
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
    let reconnect: @MainActor () -> Void
    var probe: PagedListProbe?

    init(state: CloudChatsListState, shown: Binding<Int>, select: @escaping @MainActor (String) -> Void,
         reconnect: @escaping @MainActor () -> Void, probe: PagedListProbe? = nil) {
        rows = state.rows
        edge = state.edge
        hasOlder = state.hasOlder
        _shown = shown
        drawnShown = shown.wrappedValue
        self.select = select
        self.reconnect = reconnect
        self.probe = probe
    }

    var body: some View {
        PagedList(direction: .down, items: rows, phase: .loaded, edge: edge,
                  loadMore: { showMore() }, retry: { reconnect() }) { item in
            Button { select(item.id) } label: {
                CloudChatRow(item: item)
            }
            .buttonStyle(.cmuxPressFill)
            .accessibilityIdentifier("cloudChats.row.\(item.id)")
        } empty: {
            ContentUnavailableView("No chats", systemImage: "bubble.left",
                                   description: Text("Tap New Chat to start one on this Cloud machine."))
        }
        .pagedIdentifier("cloudChats.list")
        .pagedProbe(probe)
    }
}

/// The adapter between a Cloud machine's chats and their list: the chats shown (`shown` of them,
/// newest first), whether more are held, and the list's edge. The screen makes it from the chat
/// hub, the gallery from fixed chats; the view holds no read of its own.
struct CloudChatsListState: Equatable {
    let rows: [CloudChatsListItem]
    let hasOlder: Bool
    let edge: PagedListEdge

    /// `newestFirst`: every chat held; `listWhole`: the hub read them all; `restStopped`: its read
    /// of older chats stopped short.
    init(newestFirst chats: [CloudChatsListItem], listWhole: Bool, restStopped: Bool, shown: Int) {
        rows = Array(chats.prefix(shown))
        hasOlder = chats.count > shown
        edge = CloudChatList.edge(hasOlder: hasOlder, listWhole: listWhole, restStopped: restStopped)
    }

    /// The machine's own chats in the hub, newest first (``CloudChatList``).
    @MainActor
    init(hub: AcpmuxHub, shown: Int) {
        let listed = CloudChatList.newest(hub.sessions.values, shown: shown)
        rows = listed.rows.map(CloudChatsListItem.init)
        hasOlder = listed.hasOlder
        edge = CloudChatList.edge(hasOlder: hasOlder, listWhole: hub.listWhole, restStopped: hub.listRestStopped)
    }
}

extension CloudMachineChatsList {
    /// One page more of the chats held, once per drawn list.
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

    init(id: String, title: String, prompt: String?) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }

    init(_ session: AcpmuxSession) {
        self.init(id: session.id, title: session.name.isEmpty ? session.harness : session.name,
                  prompt: session.lastPrompt.flatMap { $0.isEmpty ? nil : $0 })
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
