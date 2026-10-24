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
    private(set) var attachments: [String] = []
    var sent = false
    var failure: String?
    /// False: shown, but no row, Submit or composer acts (PR B security review H1).
    var actionable = true

    @ObservationIgnored var send: (PushReply.Action) -> Void = { _ in }
    @ObservationIgnored var openApp: () -> Void = {}
    @ObservationIgnored var presentPicker: (UIViewController) -> Void = { _ in }
    @ObservationIgnored private var pickerDelegate: PickerDelegate?

    func load(payload: PushPayload?, group: PushAppGroup?) {
        self.payload = payload
        form = payload.map(PushForm.init(payload:))
        outbox = PushOutbox(group: group)
        let markerDirectory = group?.directory ?? FileManager.default.temporaryDirectory
        let unlocked = PushProtectedMarker(directory: markerDirectory).isUnlocked()
        showsContent = PushForm.showsContent(previews: payload?.previews ?? true, unlocked: unlocked)
        // The saved chat holds the person's own messages: only while unlocked (review L1).
        if showsContent, PushForm.loadsSnapshot(unlocked: unlocked), let payload, let mac = payload.mac, let session = payload.sessionId {
            snapshot = PushSnapshotStore(group: group)?.load(mac: mac, session: session)
        }
    }

    /// A handover is possible: the build shares an App Group with the app.
    var canHandOver: Bool { outbox != nil }

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
        guard let action = form?.composerReply(draft, attachments: attachments) else { return }
        deliver(action)
        draft = ""
        attachments = []
    }

    private func deliver(_ action: PushReply.Action) {
        guard canHandOver else { return openApp() }
        send(action)
    }

    /// "+": photos from PHPicker (no library permission needed), copied into the outbox.
    func pickPhotos() {
        guard let outbox else { return openApp() }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 4
        let picker = PHPickerViewController(configuration: config)
        let delegate = PickerDelegate(folder: outbox.attachments) { [weak self] names in
            self?.attachments += names
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        presentPicker(picker)
    }
}

/// Copies picked images into the outbox's attachments folder.
@MainActor
private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let folder: URL
    let done: @MainActor @Sendable ([String]) -> Void

    init(folder: URL, done: @escaping @MainActor @Sendable ([String]) -> Void) {
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
                Task { @MainActor in done([name]) }
            }
        }
    }
}

struct NotificationContentView: View {
    let model: NotificationContentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let payload = model.payload {
                header(payload)
                if model.showsContent {
                    preview(payload)
                    if model.actionable, let form = model.form { options(form) }
                    if model.sent {
                        Label("Opening cmux to send…", systemImage: "paperplane").font(.footnote).foregroundStyle(.secondary)
                    } else if let failure = model.failure {
                        Text(failure).font(.footnote).foregroundStyle(.red)
                    }
                    if model.actionable, model.form?.hasComposer == true { composer }
                } else {
                    Label("Unlock to see this notification", systemImage: "lock").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Open cmux to see this notification.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private func header(_ payload: PushPayload) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(payload.kind)).foregroundStyle(tint(payload.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(payload)).font(.headline).lineLimit(1)
                Text([payload.placeName, payload.macDisplayName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let state = payload.state { stateBadge(state) }
        }
        .accessibilityElement(children: .combine)
    }

    private func headline(_ payload: PushPayload) -> String {
        let agent = payload.agent ?? String(localized: "Your agent")
        switch payload.kind {
        case .question: return String(localized: "\(agent) asks")
        case .permission: return String(localized: "\(agent) needs permission")
        case .completed: return String(localized: "\(agent) finished")
        case .failed: return String(localized: "\(agent) stopped with an error")
        case .chief: return String(localized: "Chief")
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bubbles(payload).enumerated()), id: \.offset) { _, message in
                    bubble(message)
                }
                if let title = payload.title, payload.kind.isAsk {
                    Text(title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                } else if let body = payload.body, payload.kind == .failed || payload.kind == .chief {
                    bubble(PushSnapshot.Message(role: .agent, text: body))
                }
            }
        }
    }

    /// The saved chat's last messages, else the payload's last lines.
    private func bubbles(_ payload: PushPayload) -> [PushSnapshot.Message] {
        if let messages = model.snapshot?.messages, !messages.isEmpty { return Array(messages.suffix(5)) }
        return payload.tail.suffix(5).map { PushSnapshot.Message(role: .agent, text: $0) }
    }

    private func bubble(_ message: PushSnapshot.Message) -> some View {
        let mine = message.role == .user
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .lineLimit(6)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? Color.white : Color.primary)
            if !mine { Spacer(minLength: 40) }
        }
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

    // MARK: Composer

    private var composer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty {
                Label("\(model.attachments.count) photo(s) attached", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if model.canHandOver {
                    Button { model.pickPhotos() } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 32, height: 32)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach photos")
                    .accessibilityIdentifier("cmux.push.attach")
                }
                if model.canHandOver {
                    TextField(model.payload?.kind == .question ? "Type an answer" : "Reply", text: $model.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                        .submitLabel(.send)
                        .onSubmit { model.sendDraft() }
                        .accessibilityIdentifier("cmux.push.composer")
                    Button { model.sendDraft() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.form?.composerReply(model.draft, attachments: model.attachments) == nil)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("cmux.push.send")
                } else {
                    // A build without the App Group cannot hand text over.
                    Button { model.openApp() } label: {
                        Label("Open in app", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cmux.push.open")
                }
            }
        }
        .padding(.top, 4)
    }
}
