#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Session Info (the Mac's Toggle Session Info)

/// Session Info, pushed over the chat: where the chat runs and on what, how much context it
/// used, what it changed and made, its permissions, and its debug views. Each value copies
/// on a tap.
struct SessionInfoScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    @State private var details: Load<AgentSessionDetails> = .loading
    @State private var permissions: Load<AgentChatPermissions> = .loading
    @State private var copied: String?
    @State private var confirmsRevoke = false
    @State private var revoking = false
    @State private var actionError: String?

    enum Load<Value: Equatable>: Equatable {
        case loading
        case loaded(Value)
        case failed(String)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AgentBrandMark(agent: store.summary.harness, size: 22, style: .brand)
                        .frame(width: 40, height: 40)
                        .background(Color.cmuxMobileSurfaceRaised, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.displayTitle).font(.headline).lineLimit(2)
                        Text("\(store.summary.agentName) · \(store.summary.workspaceTitle)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            environment
            context
            activity
            permissionSection
            Section("Conversation") {
                NavigationLink {
                    ReplayConversationScreen(store: store)
                } label: {
                    Label("Replay Conversation", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("chat.info.replay")
                NavigationLink {
                    EventInspectorScreen(journal: store.source.eventJournal, sessionID: store.summary.id)
                } label: {
                    Label("Event Inspector", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("chat.info.inspector")
            }
        }
        .navigationTitle("Session Info")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copied)
        .task { await reload() }
        .refreshable { await reload() }
        .chatDemoReceiver(store: store, surface: surface)
    }

    // MARK: Sections

    @ViewBuilder private var environment: some View {
        Section("Environment") {
            switch details {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            case .loaded(let details):
                row("Host", details.host, id: "host")
                row("Folder", details.cwd, id: "cwd")
                if let branch = store.summary.branch { row("Branch", branch, id: "branch") }
                row("Agent name", details.name, id: "name")
                row("Session ID", details.sessionID, id: "session")
                row("Harness session ID", details.harnessSessionID, id: "harnessSession")
            }
        }
    }

    @ViewBuilder private var context: some View {
        if case .loaded(let details) = details {
            Section(details.status.harness) {
                ForEach(details.status.fields.filter { ["Model", "Effort", "Context", "Usage limits", "Version"].contains($0.label) }) { field in
                    row(field.label, field.value, id: "status.\(field.label)")
                }
            }
        }
    }

    @ViewBuilder private var activity: some View {
        Section("Activity") {
            Button {
                surface.openAllChanges(of: store)
            } label: {
                Label("Agent Edits", systemImage: "plus.forwardslash.minus")
            }
            .disabled(!AgentChatSurface.hasAgentEdits(store))
            Button {
                surface.showArtifacts = true
            } label: {
                Label("Files and Artifacts", systemImage: "folder")
            }
            NavigationLink {
                SubagentsScreen(store: store, surface: surface)
            } label: {
                Label(store.subagents.isEmpty ? "Subagents" : "Subagents (\(store.subagents.count))", systemImage: "person.2.wave.2")
            }
        }
        .tint(.primary)
    }

    @ViewBuilder private var permissionSection: some View {
        Section {
            LabeledContent("Allow for This Chat") {
                switch permissions {
                case .loading: ProgressView()
                case .failed: Text("Unknown")
                case .loaded(let state): Text(state.allowedForChat ? "On" : "Off")
                }
            }
            .accessibilityIdentifier("chat.info.allowForChat")
            Button("Revoke Chat Permission", systemImage: "hand.raised", role: .destructive) { confirmsRevoke = true }
                .disabled(revoking || permissions != .loaded(AgentChatPermissions(allowedForChat: true, openGroups: openGroups)))
                .accessibilityIdentifier("chat.info.revoke")
                // Anchored to the row it confirms (its popover points at it).
                .confirmationDialog("Revoke Allow for This Chat?", isPresented: $confirmsRevoke, titleVisibility: .visible) {
                    Button("Revoke", role: .destructive) { revoke() }
                        .accessibilityIdentifier("chat.info.revokeConfirm")
                } message: {
                    Text("\(store.summary.agentName) asks again before each change in this chat.")
                }
            Button("Check and Retry Permission", systemImage: "arrow.clockwise") {
                store.checkAndRetryPermission()
                Task { await reloadPermissions() }
            }
            .disabled(!store.permissionAnswerUncertain)
            .accessibilityIdentifier("chat.info.retryPermission")
            Button("Refresh Permissions", systemImage: "arrow.clockwise.circle") {
                store.source.refreshPermissions()
                Task { await reloadPermissions() }
            }
            .accessibilityIdentifier("chat.info.refreshPermissions")
        } header: {
            Text("Permissions")
        } footer: {
            if let actionError {
                Text(actionError).foregroundStyle(Color.cmuxMobileDanger)
            } else if case .failed(let message) = permissions {
                Text(message)
            } else {
                Text("Allow for This Chat is given on the Mac. Revoke it here and the agent asks again before each change.")
            }
        }
        .tint(.primary)
    }

    private var openGroups: Int {
        if case .loaded(let state) = permissions { return state.openGroups }
        return 0
    }

    /// One value; a tap copies it.
    @ViewBuilder private func row(_ label: String, _ value: String?, id: String) -> some View {
        let shown = value.flatMap { $0.isEmpty ? nil : $0 }
        Button {
            guard let shown else { return }
            UIPasteboard.general.string = shown
            copied = id
        } label: {
            LabeledContent(String(localized: String.LocalizationValue(label))) {
                Text(copied == id ? String(localized: "Copied") : (shown ?? String(localized: "Not reported")))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
            }
        }
        .tint(.primary)
        .disabled(shown == nil)
        .accessibilityHint(shown == nil ? "" : String(localized: "Copies the value"))
        .accessibilityIdentifier("chat.info.\(id)")
    }

    // MARK: Reads and actions

    private func reload() async {
        do {
            details = .loaded(try await store.source.sessionDetails())
        } catch {
            details = .failed(Self.message(error))
        }
        await reloadPermissions()
    }

    private func reloadPermissions() async {
        do {
            permissions = .loaded(try await store.source.chatPermissions())
        } catch {
            permissions = .failed(Self.message(error))
        }
    }

    private func revoke() {
        revoking = true
        actionError = nil
        Task { @MainActor in
            do {
                try await store.source.revokeChatPermission()
            } catch {
                actionError = Self.message(error)
            }
            await reloadPermissions()
            revoking = false
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - Event Inspector (the Mac's Toggle Event Inspector, its Session view)

/// The raw records this phone received for the chat, newest first: kind, method and seq,
/// and each record's JSON. Filter, Copy as JSON Lines and Clear, as on the Mac.
struct EventInspectorScreen: View {
    let journal: AgentEventJournal?
    let sessionID: String
    @State private var filter = ""
    @State private var copied = false

    var body: some View {
        Group {
            if let journal {
                let rows = journal.events.filter { $0.matches(filter) }
                List {
                    Section {
                        ForEach(rows.reversed()) { event in
                            NavigationLink {
                                EventInspectorDetail(event: event)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.subheadline.monospaced()).lineLimit(2)
                                    Text("\(event.dir) · \(event.kind) · \(event.at.formatted(.dateTime.hour().minute().second()))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("chat.inspector.row")
                        }
                    } header: {
                        Text(summary(shown: rows.count, total: journal.events.count, dropped: journal.dropped))
                            .accessibilityIdentifier("chat.inspector.count")
                    }
                }
                .overlay {
                    if journal.events.isEmpty {
                        ContentUnavailableView("No events yet", systemImage: "list.bullet.rectangle",
                                               description: Text("Records from the Mac show here as they arrive."))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Copy as JSON Lines", systemImage: "doc.on.doc") {
                                // Raw tool output: kept on this iPhone (no Universal Clipboard) and
                                // gone from the pasteboard after ten minutes.
                                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: journal.jsonLines(rows)]],
                                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
                                copied = true
                            }
                            .disabled(rows.isEmpty)
                            Button("Clear", systemImage: "trash", role: .destructive) { journal.clear() }
                                .disabled(journal.events.isEmpty)
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .accessibilityIdentifier("chat.inspector.more")
                    }
                }
            } else {
                ContentUnavailableView("No events for this chat", systemImage: "list.bullet.rectangle",
                                       description: Text("This chat's records don't come from a Mac."))
            }
        }
        .searchable(text: $filter, prompt: "Filter")
        .sensoryFeedback(.success, trigger: copied)
        .navigationTitle("Event Inspector")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(shown: Int, total: Int, dropped: Int) -> String {
        var text = shown == total ? String(localized: "\(total) events") : String(localized: "\(shown) of \(total) events")
        if dropped > 0 { text += " · " + String(localized: "\(dropped) older dropped") }
        return text
    }
}

struct EventInspectorDetail: View {
    let event: AgentInspectorEvent

    var body: some View {
        let json = event.json
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let total = json.total {
                    Text("Cut at \(json.text.count) of \(total) characters").font(.footnote).foregroundStyle(.secondary)
                }
                Text(json.text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("chat.inspector.json")
            }
            .padding()
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = json.text }
            }
        }
    }
}

// MARK: - Replay Conversation (the Mac's webviews/src/replay)

/// A chat's records played back into a read-only transcript, at the recorded pace with long
/// pauses cut to 2 s: play and pause, speed, a scrubber with the tool calls marked, and
/// Previous and Next tool call. Nothing is sent to the agent.
struct ReplayConversationScreen: View {
    let store: AgentChatStore
    @State private var player = ChatReplayPlayer()

    var body: some View {
        Group {
            switch player.state {
            case .loading:
                ProgressView("Loading this chat's history…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load this chat's history.", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await player.load(store) } }
                }
            case .empty:
                ContentUnavailableView("Nothing to replay yet.", systemImage: "arrow.counterclockwise")
            case .ready:
                if let replay = player.store {
                    AgentChatTranscript(store: replay, surface: player.surface)
                        .background(Color.cmuxMobileBackground)
                        .overlay(alignment: .bottom) {
                            ChatReplayControls(player: player)
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                                    player.surface.stackHeight = frame.height
                                    player.surface.stackMaxY = frame.maxY
                                    player.surface.drawnStackHeight = frame.height
                                    player.surface.stackHeightFrame?(frame.height)
                                }
                        }
                }
            }
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .task { await player.load(store) }
        .onDisappear { player.pause() }
    }
}

/// The replay's playhead and the store it plays into.
@MainActor
@Observable
final class ChatReplayPlayer {
    enum State: Equatable { case loading, failed(String), empty, ready }

    static let speeds: [Double] = [0.5, 1, 2, 4, 8, 16]

    private(set) var state: State = .loading
    private(set) var recording = AgentReplayRecording(steps: [], truncated: false)
    private(set) var time: TimeInterval = 0
    private(set) var playing = false
    var speed: Double = 1
    /// Where the scrubber is while a finger drags it (nil: not dragging).
    var scrubTime: TimeInterval?
    /// A finger is on the scrubber.
    var scrubbing = false
    /// The transcript the replay draws (rebuilt when the playhead moves back).
    private(set) var store: AgentChatStore?
    let surface = AgentChatSurface()
    @ObservationIgnored private var source: ReplaySource?
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var summary: AgentSessionSummary?
    /// How often the playhead moves while playing.
    static let tick: Duration = .milliseconds(100)

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        surface.holdsTranscript = false
    }

    func load(_ chat: AgentChatStore) async {
        state = .loading
        summary = chat.summary
        do {
            recording = try await chat.source.replayRecording()
        } catch {
            state = .failed(SessionInfoScreen.message(error))
            return
        }
        guard !recording.steps.isEmpty else {
            state = .empty
            return
        }
        rebuild()
        state = .ready
        play()
    }

    var duration: TimeInterval { recording.duration }
    /// The tool calls' times (the scrubber's ticks), each once.
    var toolCallTimes: [TimeInterval] { Array(Set(recording.steps.filter(\.isToolCall).map(\.time))).sorted() }

    func play() {
        guard state == .ready else { return }
        if time >= duration { seek(to: 0) }
        playing = true
        task?.cancel()
        let clock = clock
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: Self.tick) } catch { return }
                guard let self, self.playing else { return }
                let next = min(self.duration, self.time + 0.1 * self.speed)
                self.seek(to: next)
                if next >= self.duration {
                    self.playing = false
                    return
                }
            }
        }
    }

    func pause() {
        playing = false
        task?.cancel()
        task = nil
    }

    func toggle() { playing ? pause() : play() }

    func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: speed) ?? 1
        speed = Self.speeds[(index + 1) % Self.speeds.count]
    }

    func previousToolCall() {
        seek(to: recording.previousToolCall(before: time) ?? 0)
    }

    func nextToolCall() {
        if let next = recording.nextToolCall(after: time) { seek(to: next) }
    }

    /// Moves the playhead: the steps up to it play into the transcript (a move back starts
    /// the transcript over and plays up to it at once).
    func seek(to newTime: TimeInterval) {
        time = min(max(0, newTime), duration)
        let played = recording.played(at: time)
        if played < applied { rebuild() }
        guard played > applied, let source else { return }
        source.play(recording.steps[applied..<played].flatMap(\.events))
        applied = played
    }

    private func rebuild() {
        guard let summary else { return }
        let source = ReplaySource(summary: summary)
        self.source = source
        store = AgentChatStore(source: source)
        applied = 0
        surface.following = true
        let played = recording.played(at: time)
        if played > 0 {
            source.play(recording.steps[0..<played].flatMap(\.events))
            applied = played
        }
    }
}

/// The replay's events, sent to its read-only store; it sends nothing anywhere.
@MainActor
final class ReplaySource: AgentSessionSource {
    let summary: AgentSessionSummary
    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []
    private var played: [AgentSessionEvent] = []

    init(summary: AgentSessionSummary) {
        var summary = summary
        summary.status = .idle
        self.summary = summary
    }

    func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        if !played.isEmpty { continuation.yield(.batch(played)) }
        continuations.append(continuation)
        return stream
    }

    func play(_ events: [AgentSessionEvent]) {
        guard !events.isEmpty else { return }
        played += events
        for continuation in continuations { continuation.yield(.batch(events)) }
    }

    /// A replay is read only.
    func send(_ intent: AgentClientIntent) {}
    var isReadOnly: Bool { true }
}

struct ChatReplayControls: View {
    let player: ChatReplayPlayer

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                // A drag moves the clock; the transcript plays to it when the finger lifts (a move
                // back replays the chat from its start, once, not per drag step).
                // A change with no drag (VoiceOver's adjust) seeks at once.
                Slider(value: Binding(get: { player.scrubTime ?? player.time }, set: { value in
                    if player.scrubbing { player.scrubTime = value } else { player.seek(to: value) }
                }), in: 0...max(player.duration, 0.1)) { editing in
                    player.scrubbing = editing
                    if !editing, let time = player.scrubTime {
                        player.scrubTime = nil
                        player.seek(to: time)
                    }
                }
                    .accessibilityLabel("Replay position")
                    .accessibilityValue(Text("\(AgentReplayRecording.clock(player.time)) of \(AgentReplayRecording.clock(player.duration))"))
                    .accessibilityIdentifier("chat.replay.position")
                // Tool-call ticks under the track.
                GeometryReader { proxy in
                    ForEach(player.toolCallTimes, id: \.self) { time in
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 1.5, height: 6)
                            .offset(x: (proxy.size.width - 28) * time / max(player.duration, 0.1) + 14, y: proxy.size.height - 4)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            HStack(spacing: 20) {
                Text("\(AgentReplayRecording.clock(player.scrubTime ?? player.time)) / \(AgentReplayRecording.clock(player.duration))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.replay.clock")
                Spacer()
                Button("Previous tool call", systemImage: "backward.end") { player.previousToolCall() }
                    .labelStyle(.iconOnly)
                Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") { player.toggle() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .accessibilityIdentifier("chat.replay.play")
                Button("Next tool call", systemImage: "forward.end") { player.nextToolCall() }
                    .labelStyle(.iconOnly)
                Spacer()
                Button {
                    player.cycleSpeed()
                } label: {
                    Text(player.speed == 0.5 ? "0.5×" : "\(Int(player.speed))×").font(.footnote.monospacedDigit().weight(.semibold))
                }
                .accessibilityLabel("Playback speed")
                .accessibilityValue(Text(player.speed == 0.5 ? "0.5×" : "\(Int(player.speed))×"))
                .accessibilityIdentifier("chat.replay.speed")
            }
            if player.recording.truncated {
                Text("Showing the first \(player.recording.steps.count) records of this chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
#endif
