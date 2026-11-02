#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileLive
import CmuxMobileNotifications
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
                    ProgressView("Loading Cloud chats…")
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
                                        preferredSession: attention?.sessionID)
            }
            .task(id: Load(mac: attention == nil ? macID : "", macs: eligibleMacIDs.sorted(),
                           live: shell.live.map(ObjectIdentifier.init), team: shell.store.activeTeamID, refresh: refresh)) {
                shell.cloudMacID = attention == nil && !macID.isEmpty ? macID : nil
                selectedLocation = nil
                locations = []
                error = nil
                guard let live = shell.live, attention != nil ? !eligibleMacIDs.isEmpty : !macID.isEmpty else {
                    loading = false
                    error = "Connect a Mac to see its Cloud chats."
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
}

private struct CloudMachineChatsScreen: View {
    let live: LiveCoordinator?
    let macID: String
    let machine: CloudChatMachine
    let preferredSession: String?
    @State private var relay: CloudChatRelay?
    @State private var selectedSession: String?
    @State private var error: String?
    @State private var refresh = 0
    @State private var openedPreferred = false

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady {
                if let preferredSession, !openedPreferred, relay.hub.sessions[preferredSession] == nil {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This chat is no longer listed on this Cloud machine."))
                } else {
                    List {
                        ForEach(relay.hub.sessions.values.filter { $0.peer == nil }.sorted { $0.id < $1.id }, id: \.id) { chat in
                            Button { selectedSession = chat.id } label: {
                                VStack(alignment: .leading) {
                                    Text(chat.name.isEmpty ? chat.harness : chat.name)
                                    if let prompt = chat.lastPrompt, !prompt.isEmpty {
                                        Text(prompt).lineLimit(2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .overlay {
                        if relay.hub.sessions.isEmpty {
                            ContentUnavailableView("No chats", systemImage: "bubble.left",
                                                   description: Text("Start a chat on this Cloud machine from your Mac."))
                        }
                    }
                }
            } else if error != nil || relay?.error != nil || relay?.hub.lastError != nil {
                ContentUnavailableView {
                    Label("Couldn't connect", systemImage: "cloud")
                } actions: { Button("Retry") { refresh += 1 } }
            } else {
                ProgressView("Connecting…")
            }
        }
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") { refresh += 1 }
            }
        }
        .navigationDestination(item: $selectedSession) { sessionID in
            if let store = relay?.store(sessionID: sessionID) {
                AgentChatScreen(store: store)
            } else {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            }
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
        .onChange(of: relay?.hub.isReady, initial: true) { _, ready in
            guard ready == true, !openedPreferred, let preferredSession,
                  relay?.hub.sessions[preferredSession]?.peer == nil,
                  relay?.hub.sessions[preferredSession] != nil else { return }
            openedPreferred = true
            selectedSession = preferredSession
        }
    }
}
#endif
