#if os(iOS)
import enum CmuxMobileModel.UserFacingError
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxSpinner
import SwiftUI
import UIKit

/// The ACP parity screens an agent chat pushes (title menu, transcript rows):
/// subagents, a subagent's own transcript, checkpoints and the handoff.
public enum AgentParityRoute: Hashable, Identifiable, Sendable {
    case subagents
    case subagent(String)
    case checkpoints
    case handoff
    /// `/continue <harness>`: the review of a continuation to that agent, straight away.
    case handoffTo(AgentHandoffTarget)
    /// Session Info (the Mac's Toggle Session Info).
    case sessionInfo
    /// The raw records this phone received (the Mac's Toggle Event Inspector).
    case eventInspector
    /// Replay Conversation.
    case replay

    public var id: String {
        switch self {
        case .subagents: "subagents"
        case .subagent(let id): "subagent-\(id)"
        case .checkpoints: "checkpoints"
        case .handoff: "handoff"
        case .handoffTo(let target): "handoff-\(target.id)"
        case .sessionInfo: "session-info"
        case .eventInspector: "event-inspector"
        case .replay: "replay"
        }
    }
}

extension View {
    /// Runs DEBUG demo commands from a screen pushed over the chat (see `AgentChatSurface.run`).
    func chatDemoReceiver(store: AgentChatStore, surface: AgentChatSurface) -> some View {
        modifier(ChatDemoReceiver(store: store, surface: surface))
    }
}

private struct ChatDemoReceiver: ViewModifier {
    let store: AgentChatStore
    let surface: AgentChatSurface
    #if DEBUG
    private let director = DemoDirector.shared

    func body(content: Content) -> some View {
        content.onChange(of: director.serial) {
            if let command = director.command { surface.run(command, store: store) }
        }
    }
    #else
    func body(content: Content) -> some View { content }
    #endif
}

struct AgentParityDestination: View {
    let route: AgentParityRoute
    let store: AgentChatStore
    let surface: AgentChatSurface

    var body: some View {
        switch route {
        case .subagents: SubagentsScreen(store: store, surface: surface)
        case .subagent(let id): SubagentTranscriptScreen(store: store, surface: surface, subagentID: id)
        case .checkpoints: CheckpointsScreen(store: store, surface: surface)
        case .handoff: HandoffScreen(store: store, surface: surface)
        case .handoffTo(let target): HandoffReviewScreen(store: store, surface: surface, target: target)
        case .sessionInfo: SessionInfoScreen(store: store, surface: surface)
            // Popped together with the chat (to the list): what the chat was reading stops.
            .onDisappear { if surface.parityRoute == .sessionInfo { ChatReadAloud.shared.stopIfReading(chat: store.summary.id) } }
        case .eventInspector: EventInspectorScreen(journal: store.source.eventJournal, sessionID: store.summary.id)
        case .replay: ReplayConversationScreen(store: store)
        }
    }
}

// MARK: Subagents

/// The glyph for a subagent's state: a spinner while it runs.
struct SubagentStateGlyph: View {
    let state: AgentSubagent.State

    var body: some View {
        Group {
            switch state {
            case .running: CmuxSpinner().controlSize(.small)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.cmuxMobileSuccess)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.cmuxMobileDanger)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .disconnected: Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .frame(width: 20, height: 20)
        .contentTransition(.symbolEffect(.replace))
    }
}

/// The transcript row for subagents started together (acpmux SubagentGroup):
/// a card with a count header and one row per subagent that opens its transcript.
struct SubagentGroupCard: View {
    let ids: [String]
    let store: AgentChatStore
    let open: (String) -> Void

    private var agents: [AgentSubagent] { ids.compactMap { store.subagent($0) } }

    var body: some View {
        let agents = agents
        let running = agents.count(where: { $0.state == .running })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2").font(.system(size: 14))
                Text(agents.count == 1 ? "1 subagent" : "\(agents.count) subagents").font(.subheadline.weight(.semibold))
                Spacer()
                Text(running > 0 ? "\(running) running" : "Done")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider().padding(.leading, 16)
            ForEach(agents) { agent in
                Button { open(agent.id) } label: {
                    HStack(spacing: 10) {
                        SubagentStateGlyph(state: agent.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(agent.state == .running ? (agent.action ?? agent.task ?? "Starting") : (agent.task ?? agent.state.label))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel("\(agent.name), \(agent.state.label)")
                .accessibilityHint("Opens its transcript")
            }
        }
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
        .animation(.cmuxMobileSnap.unlessReduceMotion, value: agents.map(\.state))
    }
}

/// Every subagent of the session, nested ones indented under their parent.
struct SubagentsScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    @State private var selected: String?
    @State private var order = SubagentOrderMemo()

    var body: some View {
        List {
            ForEach(order.ordered(store.subagents), id: \.agent.id) { entry in
                Button { selected = entry.agent.id } label: {
                    HStack(spacing: 12) {
                        SubagentStateGlyph(state: entry.agent.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.agent.name).font(.body).lineLimit(1)
                            Text(subtitle(entry.agent)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(Duration.seconds(entry.agent.duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        // Drill-down affordance, as on every pushed row.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, CGFloat(entry.depth) * 24)
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 8, for: .scrollContent)
        .overlay {
            if store.subagents.isEmpty {
                ContentUnavailableView("No subagents", systemImage: "person.2.wave.2",
                                       description: Text("Each subagent has its own transcript."))
            }
        }
        .chatDemoReceiver(store: store, surface: surface)
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { id in
            SubagentTranscriptScreen(store: store, surface: surface, subagentID: id)
        }
    }

    private func subtitle(_ agent: AgentSubagent) -> String {
        let status = agent.state == .running ? (agent.action ?? "Working") : agent.state.label
        guard let task = agent.task, task != agent.name else { return status }
        return "\(status) · \(task)"
    }
}

/// A subagent's own transcript: the "Subagent of" pill, its task, then its rows by the chat's
/// rules (tool groups, edits, nested subagent groups), then its state. Drawn by the chat's
/// transcript list (`SubagentTranscriptHost`), which measures its rows and holds the reader's
/// place as rows above them change height.
struct SubagentTranscriptScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    let subagentID: String
    /// DEBUG rig: measures how far from the end a following reader gets (`FollowProbe`).
    let probe: FollowProbe?
    @State private var nested: String?

    init(store: AgentChatStore, surface: AgentChatSurface, subagentID: String, probe: FollowProbe? = nil) {
        self.store = store
        self.surface = surface
        self.subagentID = subagentID
        self.probe = probe
    }

    var body: some View {
        if let agent = store.subagent(subagentID) {
            SubagentTranscriptRepresentable(store: store, subagentID: subagentID, probe: probe) { nested = $0 }
                .ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .topLeading) {
                    if let probe {
                        Text(probe.summary)
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("chat.subagent.followprobe")
                    }
                }
                .background(Color.cmuxMobileBackground)
                .chatDemoReceiver(store: store, surface: surface)
                .navigationTitle(agent.name)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $nested) { id in
                    SubagentTranscriptScreen(store: store, surface: surface, subagentID: id)
                }
        } else {
            ContentUnavailableView("Subagent not found", systemImage: "person.2.slash")
        }
    }
}

/// Whether a subagent transcript follows its end, and how its size changes hold the reader.
struct SubagentFollow: Equatable {
    enum Anchor { case top, bottom }

    /// The reader is on the end (within 60 pt), by their own scroll or at rest there.
    var follows = false

    /// Where size changes anchor: the end only while following a running subagent (growth keeps
    /// the end in place in the same pass); otherwise the top, so rows measured as the reader
    /// scrolls (a finished transcript's 15,000 pt log) move nothing on screen.
    func sizeChangeAnchor(running: Bool) -> Anchor {
        follows && running ? .bottom : .top
    }

    /// A scroll geometry change; true when the view should scroll to its end (rows came in below
    /// a reader at rest on the end of a running subagent).
    mutating func changed(atEnd: Bool, grew: Bool, scrolling: Bool, running: Bool) -> Bool {
        if scrolling {
            // The reader's own scroll decides.
            follows = atEnd
            return false
        }
        if atEnd {
            follows = true
            return false
        }
        return follows && running && grew
    }

    /// The content offset after the content's height changes from `old` to `new` under `anchor`
    /// (SwiftUI's size-change anchor: the top keeps the offset, the bottom keeps the distance to
    /// the end).
    static func offset(_ offset: Double, anchor: Anchor, old: Double, new: Double) -> Double {
        anchor == .bottom ? offset + (new - old) : offset
    }
}

/// How far below the screen the end of a following subagent transcript got, over every layout
/// pass while it grew (the list rig's `CMUX_MOBILE_LIST_EDGE=follow`).
@MainActor @Observable
public final class FollowProbe {
    /// Samples count once armed (the stream started).
    @ObservationIgnored public var armed = false
    @ObservationIgnored private(set) var samples = 0
    @ObservationIgnored private(set) var growths = 0
    @ObservationIgnored private(set) var maxGap: CGFloat = 0
    /// Redrawn twice a second, not per sample (the overlay would add a redraw per frame).
    private(set) var summary = "follow probe: waiting"
    @ObservationIgnored private var shownAt = Date.distantPast

    public init() {}

    func sample(gap: CGFloat, grew: Bool) {
        guard armed else { return }
        samples += 1
        if grew { growths += 1 }
        maxGap = max(maxGap, gap)
        if Date().timeIntervalSince(shownAt) > 0.5 {
            shownAt = Date()
            summary = "follow gap max \(Int(maxGap.rounded())) pt over \(samples) passes, \(growths) growths"
        }
    }
}

/// A subagent transcript's first row: the agent that started it.
struct SubagentOfPill: View {
    let parent: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
            Text("Subagent of \(parent)")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(Color.cmuxMobileFill, in: .capsule)
    }
}


// MARK: Checkpoints

/// Loading state shared by the parity screens.
enum ParityLoad<Value> {
    case loading
    case loaded(Value)
    case unavailable(String)
    case failed(String)
}

/// Repository checkpoints around the session's turns (web acpmux/checkpoints):
/// newest first, each restorable after a confirmation.
struct CheckpointsScreen: View {
    /// The rows' text column: the 24 pt state glyph, then 12 pt. The footer starts there too.
    static let column = CmuxMobileListColumn(mark: 24, gap: 12)
    let store: AgentChatStore
    let surface: AgentChatSurface
    @State private var load: ParityLoad<[AgentCheckpoint]> = .loading
    @State private var confirming: AgentCheckpoint?
    @State private var restoring: String?
    @State private var toast: CmuxMobileToast?
    @State private var restoredTrigger = 0

    var body: some View {
        Group {
            switch load {
            case .loading:
                CmuxSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                ContentUnavailableView {
                    Label("Checkpoints unavailable", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                } description: {
                    Text(message)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load checkpoints", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    RetryButton("Try Again") { await reload() }
                }
            case .loaded(let checkpoints):
                List {
                    Section {
                        ForEach(checkpoints) { checkpoint in
                            row(checkpoint)
                                .swipeActions(edge: .trailing) {
                                    Button("Restore", systemImage: "clock.arrow.circlepath") { confirming = checkpoint }
                                        .tint(Color(uiColor: .systemOrange))
                                }
                        }
                    } footer: {
                        Text("Restore puts the files back; the current state is checkpointed first.")
                            .cmuxMobileTextColumn(.fixed(CheckpointsScreen.column))
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if checkpoints.isEmpty {
                        ContentUnavailableView("No checkpoints", systemImage: "clock.arrow.circlepath",
                                               description: Text("A checkpoint is saved before and after file changes."))
                    }
                }
            }
        }
        .chatDemoReceiver(store: store, surface: surface)
        .navigationTitle("Checkpoints")
        .navigationBarTitleDisplayMode(.inline)
        .cmuxMobileToast($toast)
        .sensoryFeedback(.success, trigger: restoredTrigger)
        .confirmationDialog("Restore this checkpoint?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { checkpoint in
            Button("Restore Files", role: .destructive) { restore(checkpoint) }
            Button("Cancel", role: .cancel) {}
        } message: { checkpoint in
            Text("\(checkpoint.files) \(checkpoint.files == 1 ? "file" : "files") in \(store.summary.workspaceTitle) go back to \(checkpoint.isBeforeTurn ? "before" : "after") “\(checkpoint.title)”. The agent's conversation is not changed.")
        }
        .task { await reload() }
        .onChange(of: surface.demoCheckpointRestore) { _, id in
            guard let id, case .loaded(let checkpoints) = load, let checkpoint = checkpoints.first(where: { $0.id == id }) else { return }
            confirming = checkpoint
        }
        .onChange(of: surface.demoConfirmRestore) {
            if let confirming { restore(confirming) }
        }
    }

    private func row(_ checkpoint: AgentCheckpoint) -> some View {
        Button { confirming = checkpoint } label: {
            HStack(alignment: .top, spacing: Self.column.gap) {
                Image(systemName: checkpoint.isBeforeTurn ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.column.mark)
                VStack(alignment: .leading, spacing: 3) {
                    Text(checkpoint.caption ?? "\(checkpoint.isBeforeTurn ? "Before" : "After") “\(checkpoint.title)”").font(.body).lineLimit(2)
                    // Branch and head on one line, count and age on the next (one line truncated the age).
                    HStack(spacing: 4) {
                        if let branch = checkpoint.branch { Text(branch).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle) }
                        if let head = checkpoint.head { Text("· \(head)").font(.footnote.monospaced()).fixedSize() }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text("\(checkpoint.files) \(checkpoint.files == 1 ? "file" : "files") · \(checkpoint.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !checkpoint.complete {
                        Label("\(checkpoint.skipped) \(checkpoint.skipped == 1 ? "file" : "files") left out (too large or ignored)", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Color.cmuxMobileWarning)
                    }
                }
                Spacer(minLength: 4)
                if restoring == checkpoint.id { CmuxSpinner().controlSize(.small) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.cmuxPressFill)
        .disabled(restoring != nil)
    }

    private func reload() async {
        do {
            load = .loaded(try await store.source.checkpoints())
        } catch let error as AgentFeatureUnavailable {
            load = .unavailable(error.message)
        } catch {
            load = .failed(UserFacingError.message(error))
        }
    }

    private func restore(_ checkpoint: AgentCheckpoint) {
        confirming = nil
        restoring = checkpoint.id
        Task {
            do {
                let summary = try await store.source.restore(checkpoint)
                toast = CmuxMobileToast(symbol: "clock.arrow.circlepath", text: summary)
                restoredTrigger += 1
                await reload()
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: UserFacingError.message(error, fallback: "Couldn't restore the checkpoint. Try again."))
            }
            restoring = nil
        }
    }
}

// MARK: Handoff

/// Continue this session in another agent (web acpmux/handoff): pick a
/// harness, review the carried context, attest a checkpoint, start.
struct HandoffScreen: View {
    /// The rows' text column: the 32 pt agent glyph, then 12 pt. The footer starts there too.
    static let column = CmuxMobileListColumn(mark: 32, gap: 12)
    let store: AgentChatStore
    let surface: AgentChatSurface
    @State private var load: ParityLoad<[AgentHandoffTarget]> = .loading
    @State private var selected: AgentHandoffTarget?

    var body: some View {
        Group {
            switch load {
            case .loading:
                CmuxSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                ContentUnavailableView {
                    Label("Can't continue elsewhere", systemImage: "arrow.triangle.branch")
                } description: {
                    Text(message)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load agents", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    RetryButton("Try Again") { await reload() }
                }
            case .loaded(let targets):
                List {
                    Section {
                        ForEach(targets) { target in
                            Button { selected = target } label: {
                                HStack(spacing: HandoffScreen.column.gap) {
                                    AgentGlyph(harness: target.family ?? target.id)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.name).font(.body)
                                        if let reason = target.unavailableReason {
                                            Text(reason).font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 48)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.cmuxPressFill)
                            .disabled(target.unavailableReason != nil)
                            .opacity(target.unavailableReason == nil ? 1 : 0.5)
                        }
                    } header: {
                        Text("Continue in another agent").cmuxMobileTextColumn(.fixed(HandoffScreen.column))
                    } footer: {
                        Text("Review the summary before sending; the new chat starts on the same Mac and folder.")
                            .cmuxMobileTextColumn(.fixed(HandoffScreen.column))
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .chatDemoReceiver(store: store, surface: surface)
        .navigationTitle("Continue in…")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { target in
            HandoffReviewScreen(store: store, surface: surface, target: target)
        }
        .task { await reload() }
        .onChange(of: surface.demoHandoffTarget) { _, id in
            if case .loaded(let targets) = load, let target = targets.first(where: { $0.id == id }) { selected = target }
        }
    }

    private func reload() async {
        do {
            load = .loaded(try await store.source.handoffTargets())
        } catch let error as AgentFeatureUnavailable {
            load = .unavailable(error.message)
        } catch {
            load = .failed(UserFacingError.message(error))
        }
    }
}

/// A round agent mark, as the Feed's avatars (`AgentAvatarMark`): the agent's own mark on its tinted circle.
struct AgentGlyph: View {
    let harness: String

    var body: some View { AgentAvatar(harness: harness, side: 32) }
}

/// Review of one continuation: what it carries, the capsule text, the checkpoint attestation.
struct HandoffReviewScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    let target: AgentHandoffTarget
    @State private var load: ParityLoad<AgentHandoffDraft> = .loading
    @State private var capsule = ""
    @State private var checkpoint = ""
    @State private var attested = false
    @State private var starting = false
    @State private var error: String?
    @State private var receipt: AgentHandoffReceipt?
    @Environment(\.dismiss) private var dismiss

    private var bytes: Int { capsule.utf8.count }

    var body: some View {
        Group {
            switch load {
            case .loading:
                VStack(spacing: 12) {
                    CmuxSpinner()
                    Text("Preparing the summary…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message), .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't prepare the continuation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .loaded(let draft):
                if let receipt {
                    ContentUnavailableView {
                        Label("Continuing in \(receipt.targetName)", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("The new chat started on \(store.summary.macName) with your reviewed summary. This chat stays as it is.")
                    } actions: {
                        Button("Done") { surface.parityRoute = nil }
                            .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary))
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    form(draft)
                }
            }
        }
        .animation(.cmuxMobileSmooth.unlessReduceMotion, value: receipt)
        .chatDemoReceiver(store: store, surface: surface)
        .navigationTitle("Review continuation")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: receipt)
        .task { await prepare() }
        .onChange(of: surface.demoHandoffFill) { _, value in
            guard let value else { return }
            checkpoint = value
            withAnimation(.cmuxMobileSnap.unlessReduceMotion) { attested = true }
        }
        .onChange(of: surface.demoHandoffStart) {
            if case .loaded(let draft) = load { start(draft) }
        }
    }

    private func form(_ draft: AgentHandoffDraft) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    AgentGlyph(harness: store.summary.harness)
                    Image(systemName: "arrow.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    AgentGlyph(harness: target.family ?? target.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue in \(target.name)").font(.headline)
                        Text("From \(store.summary.agentName) in \(store.summary.workspaceTitle)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Carried context") {
                ForEach(draft.coverage) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Text(item.status.rawValue.capitalized)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(item.status == .included ? Color.cmuxMobileSuccess : (item.status == .summarized ? .primary : .secondary))
                    }
                }
            }
            Section {
                TextField("A saved commit, stash, or backup reference", text: $checkpoint)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("I saved the working changes, including the files I need to keep.", isOn: $attested)
                    .font(.callout)
                    // Green when on, not the chat's neutral tint (a white track in Dark Mode).
                    .toggleStyle(.cmuxMobileSwitch)
            } header: {
                Text("Repository checkpoint")
            } footer: {
                Text("Save a repository checkpoint before continuing.")
            }
            Section {
                TextEditor(text: $capsule)
                    .font(.callout)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Context to carry forward")
            } header: {
                Text("Context to carry forward")
            } footer: {
                Text("\(bytes.formatted()) of \(draft.maxBytes.formatted()) bytes")
                    .foregroundStyle(bytes > draft.maxBytes ? Color.cmuxMobileDanger : .secondary)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color.cmuxMobileDanger) }
            }
            Section {
                Button("Discard continuation", role: .destructive) {
                    Task {
                        await store.source.discardHandoff(draft)
                        dismiss()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Button {
                start(draft)
            } label: {
                HStack(spacing: 8) {
                    if starting { CmuxSpinner(tint: Color.cmuxMobileOnAccent) }
                    Text(starting ? "Starting…" : "Continue in \(target.name)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary))
            .disabled(!canStart(draft))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .accessibilityIdentifier("handoff.start")
        }
        .animation(.cmuxMobileSnap.unlessReduceMotion, value: error)
    }

    private func canStart(_ draft: AgentHandoffDraft) -> Bool {
        !starting && attested && !checkpoint.trimmingCharacters(in: .whitespaces).isEmpty && bytes <= draft.maxBytes && !capsule.isEmpty
    }

    private func prepare() async {
        guard case .loading = load else { return }
        do {
            let draft = try await store.source.prepareHandoff(to: target)
            capsule = draft.capsule
            checkpoint = draft.checkpointReference ?? ""
            load = .loaded(draft)
        } catch let error as AgentFeatureUnavailable {
            load = .unavailable(error.message)
        } catch {
            load = .failed(UserFacingError.message(error))
        }
    }

    private func start(_ draft: AgentHandoffDraft) {
        guard canStart(draft) else { return }
        var reviewed = draft
        reviewed.capsule = capsule
        reviewed.checkpointReference = checkpoint.trimmingCharacters(in: .whitespaces)
        starting = true
        error = nil
        Task {
            do {
                receipt = try await store.source.startHandoff(reviewed)
            } catch {
                self.error = UserFacingError.message(error, fallback: "Couldn't start the handoff. Try again.")
            }
            starting = false
        }
    }
}

// MARK: Artifacts

/// The session's artifacts browser (title menu "Files and artifacts", toolbar button).
struct SessionArtifactsSheet: View {
    let store: AgentChatStore
    let surface: AgentChatSurface

    var body: some View {
        let collected = store.artifacts
        ArtifactsBrowser(
            title: "Files and Artifacts",
            artifacts: collected.artifacts,
            source: collected.source(fallback: store.source.artifactSource),
            state: surface.artifacts,
            emptyMessage: "Files, folders, images and links \(store.summary.agentName) reads, edits, runs or mentions show up here."
        )
    }
}
#endif
