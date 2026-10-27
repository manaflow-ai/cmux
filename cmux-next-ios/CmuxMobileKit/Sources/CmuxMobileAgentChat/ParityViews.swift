#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileDiff
import SwiftUI
import UIKit

/// The ACP parity screens an agent chat pushes (title menu, transcript rows):
/// subagents, a subagent's own transcript, checkpoints and the handoff.
public enum AgentParityRoute: Hashable, Identifiable, Sendable {
    case subagents
    case subagent(String)
    case checkpoints
    case handoff

    public var id: String {
        switch self {
        case .subagents: "subagents"
        case .subagent(let id): "subagent-\(id)"
        case .checkpoints: "checkpoints"
        case .handoff: "handoff"
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
            case .running: ProgressView().controlSize(.small)
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
                .buttonStyle(.plain)
                .accessibilityLabel("\(agent.name), \(agent.state.label)")
                .accessibilityHint("Opens its transcript")
            }
        }
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
        .animation(.cmuxMobileSnap, value: agents.map(\.state))
    }
}

/// Every subagent of the session, nested ones indented under their parent.
struct SubagentsScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    @State private var selected: String?

    private var ordered: [(agent: AgentSubagent, depth: Int)] {
        var out: [(AgentSubagent, Int)] = []
        func visit(_ parent: String?, depth: Int) {
            for agent in store.subagents where agent.parent == parent {
                out.append((agent, depth))
                visit(agent.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return out
    }

    var body: some View {
        List {
            ForEach(ordered, id: \.agent.id) { entry in
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
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 8, for: .scrollContent)
        .overlay {
            if store.subagents.isEmpty {
                ContentUnavailableView("No subagents", systemImage: "person.2.wave.2",
                                       description: Text("When \(store.summary.agentName) splits work across subagents, each one shows up here with its own transcript."))
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

/// A subagent's own transcript: the "Subagent of" pill, its task, then its
/// rows by the chat's rules (tool groups, edits, nested subagent groups).
struct SubagentTranscriptScreen: View {
    let store: AgentChatStore
    let surface: AgentChatSurface
    let subagentID: String
    @State private var nested: String?

    var body: some View {
        if let agent = store.subagent(subagentID) {
            let turn = agent.asTurn
            let rows = turn.rows
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 12, weight: .semibold))
                        Text("Subagent of \(agent.parent.flatMap { store.subagent($0)?.name } ?? store.summary.name)")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.cmuxMobileFill, in: .capsule)
                    if let task = agent.task {
                        Text(task)
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: 20, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    ForEach(rows) { row in
                        SubagentRowView(row: row, turn: turn, store: store, isLast: row.id == rows.last?.id) { nested = $0 }
                    }
                    HStack(spacing: 8) {
                        SubagentStateGlyph(state: agent.state)
                        Text(agent.state == .running ? (agent.action ?? "Working") : agent.state.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.top)
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

/// A transcript row inside a subagent (no permission or question cards: those reach the parent).
struct SubagentRowView: View {
    let row: TurnRow
    let turn: AgentTurn
    let store: AgentChatStore
    let isLast: Bool
    let open: (String) -> Void

    var body: some View {
        switch row {
        case .message(_, let markdown):
            StreamingMarkdown(markdown: markdown, isStreaming: turn.status == .running && isLast)
        case .thought(_, let text):
            ThoughtRow(text: text, isLive: turn.status == .running && isLast)
        case .tool(let call):
            // One row (same id) as the run grows into a group: swap in
            // place instead of crossfading two labels over each other.
            ToolRowView(call: call).transition(.identity)
        case .toolGroup(_, let calls):
            ToolGroupView(calls: calls, turnRunning: turn.status == .running).transition(.identity)
        case .edit(let call):
            if call.isRunning {
                ToolRowView(call: call)
            } else {
                DiffSnippet(call: call, changeSet: turn.changeSet ?? DiffChangeSet(id: call.id, title: "Changes", subtitle: "", files: []))
            }
        case .plan(_, let entries):
            PlanCard(entries: entries)
        case .subagents(_, let ids):
            SubagentGroupCard(ids: ids, store: store, open: open)
        case .permission, .question:
            EmptyView()
        }
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button("Try again") { Task { await reload() } }
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
                        Text("Restoring puts the files in \(store.summary.workspaceTitle) back the way they were. The current state is checkpointed first, so a restore can be undone.")
                            .cmuxMobileTextColumn(.fixed(CheckpointsScreen.column))
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if checkpoints.isEmpty {
                        ContentUnavailableView("No checkpoints yet", systemImage: "clock.arrow.circlepath",
                                               description: Text("A checkpoint is saved before and after each turn that changes files."))
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
                if restoring == checkpoint.id { ProgressView().controlSize(.small) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(restoring != nil)
    }

    private func reload() async {
        do {
            load = .loaded(try await store.source.checkpoints())
        } catch let error as AgentFeatureUnavailable {
            load = .unavailable(error.message)
        } catch {
            load = .failed(error.localizedDescription)
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
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: error.localizedDescription)
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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button("Try again") { Task { await reload() } }
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
                            .buttonStyle(.plain)
                            .disabled(target.unavailableReason != nil)
                            .opacity(target.unavailableReason == nil ? 1 : 0.5)
                        }
                    } header: {
                        Text("Continue in another agent").cmuxMobileTextColumn(.fixed(HandoffScreen.column))
                    } footer: {
                        Text("\(store.summary.agentName) writes a summary of this chat for the new agent. You review it before anything is sent. The new chat starts on \(store.summary.macName) in the same folder.")
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
            load = .failed(error.localizedDescription)
        }
    }
}

/// A round agent mark: the harness glyph on a raised circle (as Feed avatars).
struct AgentGlyph: View {
    let harness: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 32)
            .background(Color.cmuxMobileSurfaceRaised, in: .circle)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch harness {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "gemini": "sparkles"
        case "opencode": "curlybraces"
        default: "sparkle"
        }
    }
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
                    ProgressView()
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
        .animation(.cmuxMobileSmooth, value: receipt)
        .chatDemoReceiver(store: store, surface: surface)
        .navigationTitle("Review continuation")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: receipt)
        .task { await prepare() }
        .onChange(of: surface.demoHandoffFill) { _, value in
            guard let value else { return }
            checkpoint = value
            withAnimation(.cmuxMobileSnap) { attested = true }
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
                    if starting { ProgressView().tint(Color.cmuxMobileOnAccent) }
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
        .animation(.cmuxMobileSnap, value: error)
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
            load = .failed(error.localizedDescription)
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
                self.error = error.localizedDescription
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
        let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
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
