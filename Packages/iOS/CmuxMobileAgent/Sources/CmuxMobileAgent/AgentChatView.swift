public import CmuxConversation
import PhotosUI
public import SwiftUI
import UniformTypeIdentifiers

/// One conversation as a simple chat: bubbles, a composer with photos and
/// files, queued messages with an always-visible remove button, failed and
/// missing files, approvals, and the deleted state.
public struct AgentChatView: View {
    @State private var model: ConversationModel
    private let preparer: AgentFilePreparer
    @State private var draft = ""
    @State private var staged: [OutgoingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var removing: ClientMessageID?
    @State private var largeWarning = false
    static let largeFile: UInt64 = 200 * 1024 * 1024

    /// Creates the view.
    /// - Parameters:
    ///   - model: The conversation (started and stopped by this view).
    ///   - filesDirectory: Where picked photos and files are written.
    public init(model: ConversationModel, filesDirectory: URL) {
        _model = State(initialValue: model)
        preparer = AgentFilePreparer(directory: filesDirectory)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.state.isDeleted {
                Text(AgentStrings.deleted).foregroundStyle(.red).padding(8)
            }
            if case .incompatible = model.connection {
                Text(AgentStrings.updateMac).foregroundStyle(.secondary).padding(8)
            } else if case .connected = model.connection {
                EmptyView()
            } else {
                Text(AgentStrings.offline).font(.footnote).foregroundStyle(.secondary).padding(4)
            }
            transcript
            composer
        }
        .navigationTitle(model.state.title ?? AgentStrings.new)
        .navigationBarTitleDisplayModeInline()
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
        .alert(AgentStrings.removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(AgentStrings.remove, role: .destructive) {
                if let id = removing { Task { try? await model.dequeue(id) } }
                removing = nil
            }
            Button(AgentStrings.keep, role: .cancel) { removing = nil }
        } message: {
            Text(AgentStrings.removeBody)
        }
        .alert(AgentStrings.largeTitle, isPresented: $largeWarning) {
            Button(AgentStrings.ok, role: .cancel) {}
        } message: {
            Text(AgentStrings.largeBody)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { for url in urls { if let a = try? await preparer.prepare(fileAt: url) { add(a) } } }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first
                    if let a = try? await preparer.prepare(data: data, suggestedName: "", type: type) { add(a) }
                }
            }
        }
    }

    private func add(_ attachment: OutgoingAttachment) {
        staged.append(attachment)
        if attachment.size > Self.largeFile { largeWarning = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.state.hasOlder {
                        ProgressView().frame(maxWidth: .infinity).task { await model.loadOlder() }
                    }
                    ForEach(model.state.items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.state.items.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.kind {
        case let .message(m):
            messageRow(m)
        case let .reasoning(t):
            Text(t).italic().foregroundStyle(.secondary).font(.footnote)
        case let .activity(a):
            Label(a.title, systemImage: a.isFinished ? "checkmark.circle" : "gearshape").font(.footnote).foregroundStyle(.secondary)
        case let .plan(entries):
            VStack(alignment: .leading) {
                ForEach(entries.indices, id: \.self) { i in
                    Label(entries[i].content, systemImage: entries[i].status == "completed" ? "checkmark.square" : "square").font(.footnote)
                }
            }
        case let .approval(r):
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title)
                if r.isPending {
                    HStack {
                        ForEach(r.options) { option in
                            Button(option.label) { Task { try? await model.answer(r.id, optionID: option.id) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case let .notice(t):
            Text(t).font(.footnote).foregroundStyle(.secondary)
        case let .error(t):
            Text(t).font(.footnote).foregroundStyle(.red)
        case let .extension(x):
            Text("\(x.namespace): \(x.type)").font(.footnote).foregroundStyle(.secondary)
        case .turnEnded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ConversationMessage) -> some View {
        let user = m.role == .user
        HStack(alignment: .top) {
            if user, let id = m.clientMessageID, isQueued(m.delivery) {
                Button { removing = id } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel(AgentStrings.remove)
            }
            if user { Spacer(minLength: 40) }
            VStack(alignment: user ? .trailing : .leading, spacing: 4) {
                if !m.text.isEmpty {
                    Text(m.text)
                        .padding(user ? 10 : 0)
                        .background(user ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
                ForEach(m.attachmentIDs, id: \.self) { id in
                    if let a = model.state.attachments[id] { fileLine(a) }
                }
                if let status = status(m.delivery) {
                    if m.delivery == .failed, let id = m.clientMessageID {
                        Button { Task { try? await model.retry(id) } } label: {
                            Label(status, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                        }
                    } else {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !user { Spacer(minLength: 40) }
        }
    }

    private func isQueued(_ d: DeliveryState?) -> Bool {
        if case .queued? = d { return true }
        return d == .uploading
    }

    private func status(_ d: DeliveryState?) -> String? {
        switch d {
        case .sending?: AgentStrings.sending
        case let .queued(n)?: AgentStrings.queued(n)
        case .uploading?: AgentStrings.waitingFiles
        case .failed?: AgentStrings.failed
        default: nil
        }
    }

    @ViewBuilder
    private func fileLine(_ a: ConversationAttachment) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
        switch a.state {
        case let .uploading(received):
            ProgressView(value: a.size == 0 ? 1 : Double(received) / Double(a.size)) { Text("\(a.name) (\(size))").font(.caption) }
                .frame(maxWidth: 220)
        case .uploaded:
            Label("\(a.name) (\(size))", systemImage: a.isImage ? "photo" : "doc").font(.caption)
        case .failed:
            Label("\(a.name) (\(size))", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        case .missing:
            Label("\(a.name): \(AgentStrings.missing)", systemImage: "questionmark.folder").font(.caption).foregroundStyle(.secondary)
                .strikethrough()
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !staged.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(staged, id: \.uploadID) { Text($0.name).font(.caption).padding(6).background(.quaternary, in: Capsule()) } }
                }
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItems, matching: nil) { Image(systemName: "photo") }
                    .accessibilityLabel(AgentStrings.photos)
                Button { importing = true } label: { Image(systemName: "paperclip") }
                    .accessibilityLabel(AgentStrings.files)
                TextField(AgentStrings.message, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                if model.state.status.isBusy {
                    Button(AgentStrings.stop) { Task { try? await model.cancelTurn() } }
                }
                Button(AgentStrings.send) {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !staged.isEmpty else { return }
                    model.send(text: text, attachments: staged)
                    draft = ""
                    staged = []
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
