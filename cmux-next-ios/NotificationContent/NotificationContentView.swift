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
    /// Photos and files "+" picked, staged for this notification's Reply.
    private(set) var attachments: [PickedAttachment] = []
    var sent = false
    var failure: String?
    /// False: shown, but no row, Submit or "+" acts (PR B security review H1).
    var actionable = true

    @ObservationIgnored var send: (PushReply.Action) -> Void = { _ in }
    @ObservationIgnored var openApp: () -> Void = {}
    @ObservationIgnored var presentPicker: (UIViewController) -> Void = { _ in }
    @ObservationIgnored private var pickerDelegate: (any NSObjectProtocol)?

    /// A file picked from Files larger than this is refused (the Mac's link carries it whole).
    nonisolated static let maxFileBytes = 25 * 1024 * 1024

    /// The system's reply field is at the bottom: iOS raises its keyboard as the long
    /// look opens and clips the card to about 300 pt above it, without resizing this
    /// view. So the view is laid out for that space: Messages' compact header (a small
    /// avatar beside the name) and a shorter history that scrolls.
    var isCompact: Bool {
        guard let payload, showsContent, actionable else { return false }
        return [.completed, .failed, .chief].contains(payload.kind)
    }

    /// When the notification arrived: a chat the app saved before it does not hold its message.
    private(set) var notifiedAt: Date?
    /// The notification's request id: what the attachments are staged under.
    private(set) var requestID: String?

    func load(payload: PushPayload?, group: PushAppGroup?, date: Date? = nil, requestID: String? = nil) {
        self.payload = payload
        if let date { notifiedAt = date }
        if let requestID { self.requestID = requestID }
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

    /// "+": a reply that takes attachments, in a build that can hand them to the app.
    var showsAttach: Bool {
        payload != nil && showsContent && actionable && canHandOver && !attachmentKinds.isEmpty
    }

    /// The conversation up to and including the notified message.
    var history: PushHistory? {
        payload.map { PushHistory(payload: $0, snapshot: snapshot, notifiedAt: notifiedAt) }
    }

    /// Who a Chief notification is from: the name and avatar the Mac set, as the app shows them.
    var chiefName: String { snapshot?.title ?? payload?.agent ?? String(localized: "Chief") }
    var chiefAvatar: String { snapshot?.avatar ?? "C" }

    /// What "+" offers: Chief's messages carry text and photos only, an agent's prompt any file.
    var attachmentKinds: AttachmentKinds {
        switch payload?.kind {
        case .question, .permission, .terminal, nil: []
        case .chief: [.photos]
        case .completed, .failed: [.photos, .files]
        }
    }

    func tap(_ row: PushForm.Row) {
        guard var form else { return }
        let action = form.tap(row)
        self.form = form
        if let action { deliver(action) }
    }

    /// Submit: the chosen options and each question's "Other" text.
    func submit() {
        guard let action = form?.answers else { return }
        deliver(action)
    }

    private func deliver(_ action: PushReply.Action) {
        guard canHandOver else { return openApp() }
        send(action)
    }

    /// Every change is staged at once: Reply may be sent any moment.
    private func setAttachments(_ items: [PickedAttachment]) {
        attachments = items
        guard let outbox, let requestID else { return }
        do {
            try outbox.stage(items.map(\.name), for: requestID)
        } catch {
            failure = String(localized: "Couldn't attach that. Open cmux to send it.")
        }
    }

    func removeAttachment(_ name: String) {
        outbox?.removeAttachments([name])
        setAttachments(attachments.filter { $0.name != name })
    }

    private func added(_ item: PickedAttachment) {
        setAttachments(attachments + [item])
    }

    /// Photos from PHPicker (no library permission needed), copied into the outbox.
    func pickPhotos() {
        guard let outbox else { return openApp() }
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .screenshots])
        config.selectionLimit = 6
        let picker = PHPickerViewController(configuration: config)
        let delegate = PickerDelegate(outbox: outbox) { [weak self] item in self?.added(item) }
        pickerDelegate = delegate
        picker.delegate = delegate
        presentPicker(picker)
    }

    /// Files from the Files app, copied into the outbox (the picker hands a copy).
    func pickFiles() {
        guard let outbox else { return openApp() }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = FilePickerDelegate(outbox: outbox) { [weak self] result in
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

/// A photo or file "+" picked: its name in the outbox, what to call it, a small thumbnail.
struct PickedAttachment: Equatable {
    var name: String
    var title: String
    var thumbnail: UIImage?
}

/// What "+" offers.
struct AttachmentKinds: OptionSet {
    let rawValue: Int
    static let photos = AttachmentKinds(rawValue: 1)
    static let files = AttachmentKinds(rawValue: 2)
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

/// Copies picked images into the outbox's attachments (`PushOutbox.adopt`).
@MainActor
private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let outbox: PushOutbox
    let done: @MainActor @Sendable (PickedAttachment) -> Void

    init(outbox: PushOutbox, done: @escaping @MainActor @Sendable (PickedAttachment) -> Void) {
        self.outbox = outbox
        self.done = done
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let outbox = outbox
        let done = done
        for result in results {
            let provider = result.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { return }
                let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                guard (try? outbox.adopt(url, as: name, move: false)) != nil else { return }
                let thumbnail = attachmentThumbnail(outbox.attachments.appendingPathComponent(name), side: AttachTray.thumbnailSize)
                let item = PickedAttachment(name: name, title: String(localized: "Photo"), thumbnail: thumbnail)
                Task { @MainActor in done(item) }
            }
        }
    }
}

/// Moves files picked in Files into the outbox's attachments (`PushOutbox.adopt`).
@MainActor
private final class FilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    struct TooLarge: Error {}

    let outbox: PushOutbox
    let done: @MainActor (Result<PickedAttachment, TooLarge>) -> Void

    init(outbox: PushOutbox, done: @escaping @MainActor (Result<PickedAttachment, TooLarge>) -> Void) {
        self.outbox = outbox
        self.done = done
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let outbox = outbox
        Task { @MainActor in
            for url in urls {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<PickedAttachment, TooLarge>? in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= NotificationContentModel.maxFileBytes else {
                        try? FileManager.default.removeItem(at: url)
                        return .failure(TooLarge())
                    }
                    let name = attachmentName(url.lastPathComponent)
                    guard (try? outbox.adopt(url, as: name, move: true)) != nil else { return nil }
                    let target = outbox.attachments.appendingPathComponent(name)
                    let isImage = UTType(filenameExtension: target.pathExtension)?.conforms(to: .image) ?? false
                    let thumbnail = isImage ? attachmentThumbnail(target, side: AttachTray.thumbnailSize) : nil
                    return .success(PickedAttachment(name: name, title: url.lastPathComponent, thumbnail: thumbnail))
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
    /// With the reply field's keyboard up: compact header 44 + history + "+" 36 + gaps fit 300 pt.
    static let compactHistoryHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let payload = model.payload {
                header(payload)
                if model.showsContent {
                    preview(payload)
                    if model.actionable, let form = model.form { options(form) }
                    if model.showsAttach, !model.sent { AttachTray(model: model) }
                    if model.sent {
                        Label("Opening cmux to send…", systemImage: "paperplane")
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
            ChiefHeader(name: model.chiefName, avatar: model.chiefAvatar, mac: payload.macDisplayName, compact: model.isCompact)
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
            if let history = model.history, !history.messages.isEmpty {
                transcript(history, maxHeight: model.isCompact ? Self.compactHistoryHeight : Self.maxHistoryHeight)
            }
            if let title = payload.title, payload.kind.isAsk {
                Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The last messages, scrolled to the newest; taller than the cap, they scroll.
    private func transcript(_ history: PushHistory, maxHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            TranscriptPreview(messages: history.messages)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { historyHeight = $0 }
        }
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(historyHeight > maxHeight ? .automatic : .hidden)
        .frame(height: min(max(historyHeight, 1), maxHeight))
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
                        if form.allowsOther(q) {
                            TextField("Other answer", text: otherBinding(q))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.quaternary, in: Capsule())
                                .padding(.vertical, 6)
                                .accessibilityIdentifier("cmux.push.other.\(q)")
                        }
                    }
                    Button { model.submit() } label: {
                        Text("Submit").font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canSubmit)
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

/// "+" and what it picked, at the foot of the long look, above the system's
/// reply field: Messages' notification reply attaches the same way. What is
/// picked goes with the next Reply.
struct AttachTray: View {
    let model: NotificationContentModel

    nonisolated static let thumbnailSize: CGFloat = 52

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                if model.attachmentKinds.contains(.photos) {
                    Button("Photos", systemImage: "photo.on.rectangle") { model.pickPhotos() }
                }
                if model.attachmentKinds.contains(.files) {
                    Button("Files", systemImage: "folder") { model.pickFiles() }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .accessibilityLabel(model.attachmentKinds.contains(.files) ? String(localized: "Attach Photos or Files") : String(localized: "Attach Photos"))
            .accessibilityIdentifier("cmux.push.attach")
            if model.attachments.isEmpty {
                Text(model.attachmentKinds.contains(.files) ? "Add photos or files to your reply" : "Add photos to your reply")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments, id: \.name) { item in tile(item) }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
                .scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.push.attachments")
    }

    private func tile(_ item: PickedAttachment) -> some View {
        let size = Self.thumbnailSize
        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = item.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 3) {
                        Image(systemName: "doc.fill").font(.title3).foregroundStyle(.secondary)
                        Text(item.title).font(.caption2).lineLimit(1).truncationMode(.middle).padding(.horizontal, 3)
                    }
                }
            }
            .frame(width: size, height: size)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button { model.removeAttachment(item.name) } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.body)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(String(localized: "Remove \(item.title)"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
    }
}
