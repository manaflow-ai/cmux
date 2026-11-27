#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileLive
import CmuxSpinner
import SwiftUI

// Auto chats in Cloud chats (`plans/cmux-next/auto-mode/DESIGN.md`, slice E), shown when
// Settings > Cloud > Auto is on: the account's Auto chats with where each one is, one opened in
// the chat view, a message sent to it, a new chat started, and Keep in Cloud. They are read
// through the Cloud service with this account's own sign-in, so the section works with no Mac.
// The words are the Mac's (``AutoChatWords``).

/// What the Auto section of Cloud chats shows now.
@MainActor
@Observable
final class AutoChatsPresentation {
    /// The account's Auto chats; nil until the section first shows.
    var model: AutoChatsModel?
    /// The page over the list.
    enum Route: Hashable {
        case chat(AutoChatRow)
        case newChat
    }

    /// The page that is open over the list: a chat, or New Chat.
    var route: Route?
    /// What reads and draws the chat that was opened last. It stays while the chat slides away.
    private(set) var opened: AutoChatsModel.Open?

    /// Opens `row`: its reading starts here, once, not when its screen is drawn.
    func open(_ row: AutoChatRow) {
        opened = model?.chat(row)
        route = .chat(row)
    }

    /// The person went back to the list: the chat's held request ends.
    func left() {
        model?.leave()
    }
}

/// The Auto section of the Cloud chats list.
struct AutoChatsSection: View {
    let auto: AutoChatsPresentation

    var body: some View {
        Section {
            if let model = auto.model {
                if model.phase == .failed {
                    Text(verbatim: AutoChatWords.loadFailed).foregroundStyle(.secondary)
                    Button(AutoChatWords.retry) { Task { await model.load() } }
                        .accessibilityIdentifier("autoChats.retry")
                } else if model.chats.isEmpty {
                    if model.phase == .loaded {
                        Text(verbatim: AutoChatWords.noChats).foregroundStyle(.secondary)
                    } else {
                        CmuxSpinner(label: Text(verbatim: AutoChatWords.auto))
                    }
                }
                ForEach(model.chats) { row in
                    Button { auto.open(row) } label: { AutoChatRowLabel(row: row) }
                        .accessibilityIdentifier("autoChats.row")
                }
                Button { auto.route = .newChat } label: {
                    Label(AutoChatWords.newChat, systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("autoChats.new")
            } else {
                CmuxSpinner(label: Text(verbatim: AutoChatWords.auto))
            }
        } header: {
            Text(verbatim: AutoChatWords.auto)
        }
    }
}

/// One Auto chat's row: its name, and where it is.
private struct AutoChatRowLabel: View {
    let row: AutoChatRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.name).lineLimit(1)
            if let line = row.place.line {
                Text(verbatim: line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the Cloud chats screen adds for its Auto section: the open chat, the New Chat page and
/// the list's load.
struct AutoChatsHost: ViewModifier {
    let auto: AutoChatsPresentation
    /// Settings > Cloud > Auto is on, and the screen is the list (not one chat from a notification).
    let enabled: Bool
    let refresh: Int
    /// Opens the existing place to make a Cloud machine.
    let makeMachine: () -> Void

    private struct Load: Hashable {
        let enabled: Bool
        let refresh: Int
    }

    func body(content: Content) -> some View {
        // The page's binding only; the load below reads the presentation itself.
        @Bindable var pages = auto
        content
            // New Chat is a page of this list, not a sheet: Cloud chats is a sheet already, and the
            // HIG shows one sheet at a time. Starting the chat puts it in New Chat's place.
            .navigationDestination(item: $pages.route) { route in
                switch route {
                case .chat:
                    if let open = auto.opened {
                        AutoChatScreen(open: open, makeMachine: makeMachine)
                    }
                case .newChat:
                    if let model = auto.model {
                        AutoNewChatScreen(model: model, started: { auto.open($0) }, makeMachine: makeMachine)
                    }
                }
            }
            .onChange(of: auto.route) { before, now in
                if case .chat = before, now == nil { auto.left() }
            }
            .task(id: Load(enabled: enabled, refresh: refresh)) {
                guard enabled else { return }
                if auto.model == nil { auto.model = AutoChatsModel.live() }
                await auto.model?.load()
            }
    }
}

/// One Auto chat: the line that says where it is, over the chat view every chat uses.
private struct AutoChatScreen: View {
    let open: AutoChatsModel.Open
    let makeMachine: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AutoChatBar(source: open.source, makeMachine: makeMachine)
            AgentChatScreen(store: open.store)
        }
    }
}

/// Where the chat is, in one line, with the one thing the person can do about it: make a Cloud
/// machine when it waits for one, or keep it in the Cloud while a machine has it.
private struct AutoChatBar: View {
    let source: AutoChatSource
    let makeMachine: () -> Void

    var body: some View {
        let row = source.row
        let line: String? = source.ended ? AutoChatWords.off : row.place.line
        let keeps = !source.ended && (row.inCloud || row.keepInCloud)
        if line != nil || keeps {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let line { Text(verbatim: line) }
                    if !source.ended, let hint = row.place.hint {
                        Text(verbatim: hint).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoChat.state")
                Spacer(minLength: 0)
                if !source.ended, row.place == .noMachine {
                    Button(AutoChatWords.newMachine, action: makeMachine)
                        .font(.footnote)
                        .accessibilityIdentifier("autoChat.newMachine")
                } else if keeps {
                    // Outside a list, the HIG's toggle is a button whose background says its state.
                    Toggle(isOn: Binding(get: { source.row.keepInCloud }, set: { source.keepInCloud($0) })) {
                        Label(AutoChatWords.keepInCloud, systemImage: "cloud")
                    }
                        .toggleStyle(.button)
                        .labelStyle(.titleAndIcon)
                        .controlSize(.small)
                        .font(.footnote)
                        .accessibilityIdentifier("autoChat.keepInCloud")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .alert(AutoChatWords.keepFailed,
                   isPresented: Binding(get: { source.keepFailed }, set: { source.keepFailed = $0 })) {}
        }
    }
}

/// New Chat: a repository and branch from the account's recent Auto chats, and a first message.
/// With no Cloud machine for Auto chats it says so in one line, with the way to make one.
private struct AutoNewChatScreen: View {
    let model: AutoChatsModel
    /// The chat started: it takes this page's place.
    let started: (AutoChatRow) -> Void
    let makeMachine: () -> Void
    @State private var repo: AutoChatRepo?
    @State private var text = ""
    /// Made once for this page's message: Start again after a failure reaches the same chat.
    @State private var messageID = UUID().uuidString
    @State private var sending = false
    @State private var failed = false

    private var chosen: AutoChatRepo? { repo ?? model.repos.first }

    private var canStart: Bool {
        chosen != nil && !sending && model.hasMachine != false
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            if model.hasMachine == false {
                Section {
                    Text(verbatim: AutoChatWords.needsMachine)
                    Button(AutoChatWords.newMachine, action: makeMachine)
                        .accessibilityIdentifier("autoChats.newMachine")
                }
            }
            if model.repos.isEmpty {
                Section {
                    Text(verbatim: AutoChatWords.noRecent).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Picker(AutoChatWords.repository, selection: Binding(get: { chosen }, set: { repo = $0 })) {
                        ForEach(model.repos) { repo in
                            Text(verbatim: "\(repo.name) · \(repo.branch)").tag(Optional(repo))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("autoChats.repository")
                }
                Section {
                    TextField(AutoChatWords.message, text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("autoChats.message")
                } footer: {
                    if failed { Text(verbatim: AutoChatWords.startFailed) }
                }
            }
        }
        .navigationTitle(AutoChatWords.newChat)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Back leaves without starting; the one action is on the trailing edge.
            ToolbarItem(placement: .confirmationAction) {
                Button(AutoChatWords.start) { start() }
                    .disabled(!canStart)
                    .accessibilityIdentifier("autoChats.start")
            }
        }
        .task { await model.readMachine() }
    }

    private func start() {
        guard let chosen, canStart else { return }
        sending = true
        failed = false
        let text = text
        let messageID = messageID
        Task {
            let outcome = await model.start(repo: chosen, text: text, messageID: messageID)
            sending = false
            switch outcome {
            case let .chat(row):
                started(row)
            case .noMachine:
                break
            case .failed:
                failed = true
            }
        }
    }
}
#endif
