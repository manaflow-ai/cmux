#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import Observation
import SwiftUI

/// Review Threads: the diff review threads of this chat's worktree on its Mac (the Mac's diff
/// page comments), each with its replies, whether it is resolved, and whether it waits on the
/// agent, was chased or stalled. The person answers or resolves a thread as the reviewer and
/// sends the threads back to this chat; the Mac writes the prompt from them, so the agent's
/// answers come back to the same threads. Behind `DiffReviewThreadsFlag`.
@MainActor @Observable
final class DiffReviewThreadsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    let backend: any DiffReviewThreadsBackend
    let macID: String
    let summary: AgentSessionSummary
    let source: any AgentSessionSource
    private(set) var root: String
    private(set) var chat: String?
    private(set) var threads: [DiffReviewThread] = []
    private(set) var phase: Phase = .loading
    /// The thread a write is on (or `send` for Send to Agent).
    private(set) var busy: String?
    var notice: String?

    init(backend: any DiffReviewThreadsBackend, store: AgentChatStore) {
        self.backend = backend
        macID = store.summary.macID
        summary = store.summary
        source = store.source
        root = store.summary.cwd
        chat = store.summary.acpmuxSessionID
    }

    /// The chat's own acpmux id and folder (`_acpmux/info`), then the threads of that folder.
    func load() async {
        if let details = try? await source.sessionDetails() {
            chat = details.sessionID
            if let cwd = details.cwd, cwd.hasPrefix("/") { root = cwd }
        }
        await refresh()
    }

    func refresh() async {
        guard root.hasPrefix("/") else {
            phase = .failed(String(localized: "This chat's folder isn't known."))
            return
        }
        do {
            threads = try await backend.reviewThreads(root: root, on: macID)
            phase = .loaded
        } catch {
            if threads.isEmpty { phase = .failed(error.localizedDescription) } else { notice = error.localizedDescription }
        }
    }

    func thread(_ id: String) -> DiffReviewThread? { threads.first { $0.id == id } }

    func reply(_ text: String, to thread: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await write(thread) { [self] in try await backend.reply(text, to: thread, root: root, on: macID) }
    }

    func setResolved(_ resolved: Bool, thread: String) async {
        _ = await write(thread) { [self] in try await backend.setResolved(resolved, thread: thread, root: root, on: macID) }
    }

    /// The threads not resolved, to this chat.
    var sendable: [DiffReviewThread] { threads.filter { !$0.resolved } }

    var canSend: Bool { chat != nil && !sendable.isEmpty && busy == nil }

    func sendBack() async {
        guard let chat else { return }
        let threads = sendable
        if await write("send", { [self] in try await backend.sendBack(threads, root: root, chat: chat, on: macID) }) {
            notice = threads.count == 1
                ? String(localized: "Sent 1 thread to \(summary.agentName).")
                : String(localized: "Sent \(threads.count) threads to \(summary.agentName).")
        }
    }

    private func write(_ what: String, _ work: () async throws -> Void) async -> Bool {
        guard busy == nil else { return false }
        busy = what
        defer { busy = nil }
        do {
            try await work()
            await refresh()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}

struct DiffReviewThreadsSheet: View {
    @State private var model: DiffReviewThreadsModel
    @Environment(\.dismiss) private var dismiss

    init(backend: any DiffReviewThreadsBackend, store: AgentChatStore) {
        _model = State(initialValue: DiffReviewThreadsModel(backend: backend, store: store))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Review Threads")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.sendBack() }
                        } label: {
                            if model.busy == "send" { ProgressView() } else { Label("Send to Agent", systemImage: "paperplane") }
                        }
                        .disabled(!model.canSend)
                        .accessibilityIdentifier("reviewThreads.send")
                    }
                }
                .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
                    Button("OK", role: .cancel) {}
                }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Threads", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
            }
        case .loaded where model.threads.isEmpty:
            ContentUnavailableView("No Review Threads", systemImage: "text.bubble",
                                   description: Text("Comments on this folder's diff on the Mac show here."))
                .refreshable { await model.refresh() }
        case .loaded:
            List {
                Section {
                    ForEach(model.threads) { thread in
                        NavigationLink {
                            DiffReviewThreadScreen(model: model, threadID: thread.id)
                        } label: {
                            DiffReviewThreadRow(thread: thread)
                        }
                    }
                } footer: {
                    Text(model.root).font(.footnote).lineLimit(1).truncationMode(.head)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.refresh() }
        }
    }
}

/// A thread's row: where it is, its comment, and its state.
struct DiffReviewThreadRow: View {
    let thread: DiffReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(thread.location).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                DiffReviewThreadBadge(state: thread.state)
            }
            Text(thread.message).font(.body).lineLimit(3)
            if !thread.replies.isEmpty {
                Text(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Stalled, Waiting on Agent (and how many times it was chased), Open or Resolved.
struct DiffReviewThreadBadge: View {
    let state: DiffReviewThread.State

    var body: some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var title: String {
        switch state {
        case .stalled: String(localized: "Stalled")
        case .awaitingAgent(let chases) where chases > 0:
            chases == 1 ? String(localized: "Chased once") : String(localized: "Chased \(chases)×")
        case .awaitingAgent: String(localized: "Waiting on agent")
        case .open: String(localized: "Open")
        case .resolved: String(localized: "Resolved")
        }
    }

    private var symbol: String {
        switch state {
        case .stalled: "exclamationmark.triangle.fill"
        case .awaitingAgent: "hourglass"
        case .open: "bubble.left"
        case .resolved: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .stalled: .red
        case .awaitingAgent: .orange
        case .open: .blue
        case .resolved: .green
        }
    }
}

/// One thread: the comment, its replies oldest first, a reply as the reviewer, Resolve / Reopen.
struct DiffReviewThreadScreen: View {
    let model: DiffReviewThreadsModel
    let threadID: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let thread = model.thread(threadID) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(thread.location).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            DiffReviewThreadBadge(state: thread.state)
                        }
                        Text(thread.message).textSelection(.enabled)
                    }
                }
                if !thread.replies.isEmpty {
                    Section("Replies") {
                        ForEach(thread.replies) { reply in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reply.isAgent ? model.summary.agentName : String(localized: "You"))
                                    .font(.footnote.weight(.semibold)).foregroundStyle(reply.isAgent ? .purple : .secondary)
                                Text(reply.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    TextField("Reply", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .accessibilityIdentifier("reviewThreads.reply")
                    Button {
                        Task {
                            if await model.reply(draft, to: thread.id) { draft = "" }
                        }
                    } label: {
                        if model.busy == thread.id { ProgressView() } else { Text("Reply") }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy != nil)
                }
                Section {
                    Button(thread.resolved ? "Reopen Thread" : "Resolve Thread",
                           systemImage: thread.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                        Task { await model.setResolved(!thread.resolved, thread: thread.id) }
                    }
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("reviewThreads.resolve")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(thread.filePath.split(separator: "/").last.map(String.init) ?? "Thread")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refresh() }
        } else {
            ContentUnavailableView("Thread Gone", systemImage: "text.bubble", description: Text("The Mac no longer has this thread."))
        }
    }
}
#endif
