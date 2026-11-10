#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileLive
import CmuxMobileNotifications
import CmuxSpinner
import SwiftUI

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
            TimelineView(.periodic(from: since, by: 1)) { context in
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
    /// How many of the machine's chats the list draws, newest first (Show Older Chats adds a page).
    @State private var shown = CloudChatList.pageSize

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady {
                if let preferredSession, !openedPreferred, relay.hub.sessions[preferredSession] == nil {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This chat is no longer listed on this Cloud machine."))
                } else {
                    let listed = CloudChatList.newest(relay.hub.sessions.values, shown: shown)
                    List {
                        ForEach(listed.rows, id: \.id) { chat in
                            Button { selectedSession = chat.id } label: {
                                VStack(alignment: .leading) {
                                    Text(chat.name.isEmpty ? chat.harness : chat.name)
                                    if let prompt = chat.lastPrompt, !prompt.isEmpty {
                                        Text(prompt).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if listed.hasOlder {
                            Section {
                                Button("Show Older Chats") { shown += CloudChatList.pageSize }
                                    .accessibilityIdentifier("cloudChats.more")
                            }
                        }
                    }
                    .overlay {
                        if relay.hub.sessions.isEmpty {
                            ContentUnavailableView("No chats", systemImage: "bubble.left",
                                                   description: Text("Tap New Chat to start one on this Cloud machine."))
                        }
                    }
                }
            } else if let cause = failure {
                CloudChatsConnectFailed(cause: cause) { refresh += 1 }
            } else {
                CloudChatsConnecting(machine: machine.name, mac: macName, since: connectingSince)
            }
        }
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
        .onChange(of: relay?.hub.isReady, initial: true) { _, ready in
            guard ready == true, !openedPreferred, let preferredSession,
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
#endif
