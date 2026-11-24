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
    /// The account's Auto chats, listed first while Settings > Cloud > Auto is on (no Mac needed).
    @State private var auto = AutoChatsPresentation()

    /// The list shows the Auto section: the setting is on, and this is not one chat from a notification.
    private var showsAuto: Bool { attention == nil && shell.settings.cloudAutoMode }

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
                if showsAuto { AutoChatsSection(auto: auto) }
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
            .modifier(AutoChatsHost(auto: auto, enabled: showsAuto, refresh: refresh) { openCloudMachines() })
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

    /// The existing place to make a Cloud machine: Settings → Cloud Machines.
    private func openCloudMachines() {
        shell.cloudChats = nil
        shell.tab = .settings
        shell.settingsPath = [.cloudMachines]
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
    /// The chats acpmux listed for `shown`, in its order (the Mac's lists read the same one).
    @State private var listed = CloudChatList.Listed()
    /// The last list read failed: the list says so and offers Retry (pull to refresh reads it too).
    @State private var listError: String?
    /// Retry and pull to refresh read the list again.
    @State private var listRetry = 0

    var body: some View {
        Group {
            if relay?.isRetired == true {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left")
            } else if let relay, relay.hub.isReady {
                // Until the whole list is read (it comes in pages, CMUX-563) an older chat may still be on its way.
                if let preferredSession, !openedPreferred, relay.hub.listWhole, relay.hub.sessions[preferredSession] == nil {
                    ContentUnavailableView("Chat unavailable", systemImage: "bubble.left",
                                           description: Text("This chat is no longer listed on this Cloud machine."))
                } else {
                    List {
                        if let listError {
                            Section {
                                Text(listError).foregroundStyle(.secondary)
                                Button("Retry") { listRetry += 1 }
                            }
                        }
                        ForEach(listed.sessions(in: relay.hub), id: \.id) { chat in
                            Button { selectedSession = chat.id } label: {
                                VStack(alignment: .leading) {
                                    Text(chat.displayName)
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
                    .refreshable { await readList(relay.hub, settle: false) }
                    .overlay {
                        if relay.hub.sessions.isEmpty, listError == nil {
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
        // page stays drawn meanwhile, and after a failed read, which the list shows with Retry).
        .task(id: ListRead(ready: relay?.hub.isReady == true, revision: relay?.hub.listRevision ?? 0,
                           shown: shown, retry: listRetry)) {
            guard let hub = relay?.hub, hub.isReady else { return }
            await readList(hub, settle: !listed.ids.isEmpty)
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

    /// Reads the first `shown` chats; `settle` waits out a burst of list changes first. A failed
    /// read keeps the last page and says it failed; the next read that succeeds clears it.
    private func readList(_ hub: AcpmuxHub, settle: Bool) async {
        if settle { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        do {
            let page = try await CloudChatList.newest(hub, shown: shown)
            guard !Task.isCancelled else { return }
            listed = page
            listError = nil
        } catch {
            guard !Task.isCancelled else { return }
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
