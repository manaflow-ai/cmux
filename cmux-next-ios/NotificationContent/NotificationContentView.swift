import CmuxMobileNotifications
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the long-press view shows for one notification.
@MainActor
@Observable
final class NotificationContentModel {
    private(set) var payload: PushPayload?
    var form: PushForm?
    private(set) var snapshot: PushSnapshot?
    private(set) var outbox: PushOutbox?
    /// False with Show previews off while the phone is locked.
    private(set) var showsContent = true
    var draft = ""
    private(set) var attachments: [ComposerBar.Attachment] = []
    var sent = false
    var failure: String?
    /// False: shown, but no row, Submit or composer acts (PR B security review H1).
    var actionable = true

    @ObservationIgnored var send: (PushReply.Action) -> Void = { _ in }
    @ObservationIgnored var openApp: () -> Void = {}
    @ObservationIgnored var presentPicker: (UIViewController) -> Void = { _ in }
    @ObservationIgnored var attachmentsChanged: ([ComposerBar.Attachment]) -> Void = { _ in }
    @ObservationIgnored private var pickerDelegate: (any NSObjectProtocol)?

    /// A file picked from Files larger than this is refused (the Mac's link carries it whole).
    nonisolated static let maxFileBytes = 25 * 1024 * 1024

    func load(payload: PushPayload?, group: PushAppGroup?) {
        self.payload = payload
        form = payload.map(PushForm.init(payload:))
        outbox = PushOutbox(group: group)
        let markerDirectory = group?.directory ?? FileManager.default.temporaryDirectory
        let unlocked = PushProtectedMarker(directory: markerDirectory).isUnlocked()
        showsContent = PushForm.showsContent(previews: payload?.previews ?? true, unlocked: unlocked)
        // The saved chat holds the person's own messages: only while unlocked (review L1).
        if showsContent, PushForm.loadsSnapshot(unlocked: unlocked), let payload, let mac = payload.mac {
            // A Chief push names the turn's session; the app saves Chief's conversation under the Mac.
            let session = payload.kind == .chief ? PushSnapshot.chiefSession : payload.sessionId
            snapshot = session.flatMap { PushSnapshotStore(group: group)?.load(mac: mac, session: $0) }
        }
    }

    /// A handover is possible: the build shares an App Group with the app.
    var canHandOver: Bool { outbox != nil }

    /// The docked reply bar: a kind that takes text, in a build that can hand it to the app.
    var showsComposer: Bool {
        payload != nil && showsContent && actionable && canHandOver && form?.hasComposer == true && !sent
    }

    /// The conversation up to and including the notified message.
    var history: PushHistory? {
        payload.map { PushHistory(payload: $0, snapshot: snapshot) }
    }

    /// Who a Chief notification is from: the name and avatar the Mac set, as the app shows them.
    var chiefName: String { snapshot?.title ?? payload?.agent ?? String(localized: "Chief") }
    var chiefAvatar: String { snapshot?.avatar ?? "C" }

    var composerPlaceholder: String {
        guard let payload else { return String(localized: "Reply") }
        if payload.kind == .question { return String(localized: "Type an answer") }
        return String(localized: "Reply to \(payload.kind == .chief ? chiefName : payload.agent ?? String(localized: "your agent"))")
    }

    func tap(_ row: PushForm.Row) {
        guard var form else { return }
        let action = form.tap(row)
        self.form = form
        if let action { deliver(action) }
    }

    /// Submit: the chosen options, with the composer's text as a lone question's "Other".
    func submit() {
        guard var form else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if form.payload.questions.count == 1, form.allowsOther(0), !text.isEmpty { form.other[0] = text }
        self.form = form
        guard let action = form.answers else { return }
        deliver(action)
        draft = ""
    }

    func sendDraft() {
        guard let action = form?.composerReply(draft, attachments: attachments.map(\.name)) else { return }
        deliver(action)
        draft = ""
        setAttachments([])
    }

    private func deliver(_ action: PushReply.Action) {
        guard canHandOver else { return openApp() }
        send(action)
    }

    private func setAttachments(_ items: [ComposerBar.Attachment]) {
        attachments = items
        attachmentsChanged(items)
    }

    func removeAttachment(_ name: String) {
        outbox?.removeAttachments([name])
        setAttachments(attachments.filter { $0.name != name })
    }

    private func added(_ item: ComposerBar.Attachment) {
        setAttachments(attachments + [item])
    }

    /// Photos from PHPicker (no library permission needed), copied into the outbox.
    func pickPhotos() {
        guard let outbox else { return openApp() }
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .screenshots])
        config.selectionLimit = 6
        let picker = PHPickerViewController(configuration: config)
        let delegate = PickerDelegate(folder: outbox.attachments) { [weak self] item in self?.added(item) }
        pickerDelegate = delegate
        picker.delegate = delegate
        presentPicker(picker)
    }

    /// Files from the Files app, copied into the outbox (the picker hands a copy).
    func pickFiles() {
        guard let outbox else { return openApp() }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = FilePickerDelegate(folder: outbox.attachments) { [weak self] result in
            switch result {
            case .success(let item): self?.added(item)
            case .failure: self?.failure = String(localized: "That file is too large to send from a notification.")
            }
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        presentPicker(picker)
    }
}

/// A picked file's thumbnail, small (ImageIO), so the extension stays inside its memory budget.
nonisolated func attachmentThumbnail(_ url: URL, side: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side * 3,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
}

/// A plain file name for an attachment: a short unique prefix, then the original
/// name (what the Mac shows), never a path.
nonisolated func attachmentName(_ original: String) -> String {
    let base = (original as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
    let clean = base.isEmpty || base.hasPrefix(".") ? "file" + base : base
    return String(UUID().uuidString.prefix(8)).lowercased() + "-" + String(clean.suffix(120))
}

/// Copies picked images into the outbox's attachments folder.
@MainActor
private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let folder: URL
    let done: @MainActor @Sendable (ComposerBar.Attachment) -> Void

    init(folder: URL, done: @escaping @MainActor @Sendable (ComposerBar.Attachment) -> Void) {
        self.folder = folder
        self.done = done
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let folder = folder
        let done = done
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { return }
                let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                let target = folder.appendingPathComponent(name)
                guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                let thumbnail = attachmentThumbnail(target, side: ComposerBar.thumbnailSize)
                let item = ComposerBar.Attachment(name: name, title: String(localized: "Photo"), thumbnail: thumbnail)
                Task { @MainActor in done(item) }
            }
        }
    }
}

/// Moves files picked in Files into the outbox's attachments folder.
@MainActor
private final class FilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    struct TooLarge: Error {}

    let folder: URL
    let done: @MainActor (Result<ComposerBar.Attachment, TooLarge>) -> Void

    init(folder: URL, done: @escaping @MainActor (Result<ComposerBar.Attachment, TooLarge>) -> Void) {
        self.folder = folder
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let folder = folder
        Task { @MainActor in
            for url in urls {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<ComposerBar.Attachment, TooLarge>? in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= NotificationContentModel.maxFileBytes else {
                        try? FileManager.default.removeItem(at: url)
                        return .failure(TooLarge())
                    }
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = attachmentName(url.lastPathComponent)
                    let target = folder.appendingPathComponent(name)
                    guard (try? FileManager.default.moveItem(at: url, to: target)) != nil else { return nil }
                    let isImage = UTType(filenameExtension: target.pathExtension)?.conforms(to: .image) ?? false
                    let thumbnail = isImage ? attachmentThumbnail(target, side: ComposerBar.thumbnailSize) : nil
                    return .success(ComposerBar.Attachment(name: name, title: url.lastPathComponent, thumbnail: thumbnail))
                }.value
                if let result { done(result) }
            }
        }
    }
}

struct NotificationContentView: View {
    let model: NotificationContentModel
    /// The history's full height; the view shows at most `maxHistoryHeight` of it and scrolls.
    @State private var historyHeight: CGFloat = 0

    static let maxHistoryHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let payload = model.payload {
                header(payload)
                if model.showsContent {
                    preview(payload)
                    if model.actionable, let form = model.form { options(form) }
                    if model.sent {
                        Label("Sending in cmux…", systemImage: "paperplane")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("cmux.push.sent")
                    } else if let failure = model.failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                } else {
                    Label("Unlock to see this notification", systemImage: "lock").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Open cmux to see this notification.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ payload: PushPayload) -> some View {
        if payload.kind == .chief {
            // Chief's own header, as its chat draws it: which Chief, on which Mac.
            ChiefHeader(name: model.chiefName, avatar: model.chiefAvatar, mac: payload.macDisplayName)
        } else {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol(payload.kind))
                    .font(.title3)
                    .foregroundStyle(tint(payload.kind))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(payload)).font(.headline).lineLimit(1)
                    Text([payload.placeName, payload.macDisplayName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let state = payload.state, payload.kind.isAsk { stateBadge(state) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func headline(_ payload: PushPayload) -> String {
        let agent = payload.agent ?? String(localized: "Your agent")
        switch payload.kind {
        case .question: return String(localized: "\(agent) asks")
        case .permission: return String(localized: "\(agent) needs permission")
        case .completed: return String(localized: "\(agent) finished")
        case .failed: return String(localized: "\(agent) stopped with an error")
        case .chief: return model.chiefName
        case .terminal: return payload.title ?? String(localized: "Terminal")
        }
    }

    private func stateBadge(_ state: PushPayload.State) -> some View {
        let text: String = switch state {
        case .waiting: String(localized: "Waiting for you")
        case .finished: String(localized: "Finished")
        case .failed: String(localized: "Error")
        case .notified: String(localized: "Notified")
        }
        return Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    private func symbol(_ kind: PushKind) -> String {
        switch kind {
        case .question: "questionmark.bubble.fill"
        case .permission: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .chief: "sparkles"
        case .terminal: "terminal.fill"
        }
    }

    private func tint(_ kind: PushKind) -> Color {
        switch kind {
        case .question, .permission: .orange
        case .completed: .green
        case .failed: .red
        case .chief: .purple
        case .terminal: .secondary
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ payload: PushPayload) -> some View {
        if payload.kind == .terminal {
            // The terminal's last screen as text.
            let lines = payload.tail + (payload.body.map { [$0] } ?? [])
            if !lines.isEmpty {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .lineLimit(12)
            }
        } else {
            if let history = model.history, !history.messages.isEmpty { transcript(history) }
            if let title = payload.title, payload.kind.isAsk {
                Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The last messages, scrolled to the newest; taller than the cap, they scroll.
    private func transcript(_ history: PushHistory) -> some View {
        ScrollView(.vertical) {
            TranscriptPreview(messages: history.messages)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { historyHeight = $0 }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(historyHeight > Self.maxHistoryHeight ? .automatic : .hidden)
        .frame(height: min(max(historyHeight, 1), Self.maxHistoryHeight))
    }

    // MARK: Options

    @ViewBuilder
    private func options(_ form: PushForm) -> some View {
        let rows = form.rows
        if !rows.isEmpty || form.showsSubmit {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0, rows[index - 1].question != row.question { questionHeader(form, row.question) }
                    else if index == 0, form.payload.questions.count > 1 { questionHeader(form, row.question) }
                    optionRow(form, row)
                    Divider().opacity(index == rows.count - 1 ? 0 : 1)
                }
                if form.showsSubmit {
                    ForEach(form.payload.questions.indices, id: \.self) { q in
                        if form.allowsOther(q), form.payload.questions.count > 1 {
                            TextField("Other answer", text: otherBinding(q)).textFieldStyle(.roundedBorder).padding(.vertical, 6)
                        }
                    }
                    Button { model.submit() } label: {
                        Text("Submit").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canSubmit && form.composerReply(model.draft, attachments: []) == nil)
                    .padding(.top, 8)
                    .accessibilityIdentifier("cmux.push.submit")
                }
            }
        }
    }

    private func questionHeader(_ form: PushForm, _ q: Int) -> some View {
        let question = form.payload.questions[q]
        return Text(question.header ?? question.question)
            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 2)
    }

    private func optionRow(_ form: PushForm, _ row: PushForm.Row) -> some View {
        Button { model.tap(row) } label: {
            HStack(spacing: 10) {
                Image(systemName: rowSymbol(form, row)).foregroundStyle(rowTint(row)).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).font(.body).foregroundStyle(row.style == .deny ? Color.red : Color.primary)
                    if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cmux.push.option.\(row.id)")
        .accessibilityAddTraits(form.isSelected(row) ? .isSelected : [])
    }

    private func rowSymbol(_ form: PushForm, _ row: PushForm.Row) -> String {
        switch row.style {
        case .choice: "circle"
        case .checkbox:
            form.payload.questions[row.question].multiSelect
                ? (form.isSelected(row) ? "checkmark.square.fill" : "square")
                : (form.isSelected(row) ? "largecircle.fill.circle" : "circle")
        case .allow: "checkmark.shield"
        case .deny: "xmark.octagon"
        }
    }

    private func rowTint(_ row: PushForm.Row) -> Color {
        switch row.style {
        case .deny: .red
        case .allow: .green
        default: .accentColor
        }
    }

    private func otherBinding(_ q: Int) -> Binding<String> {
        Binding(get: { model.form?.other[q] ?? "" }, set: { model.form?.other[q] = $0 })
    }

}
