#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// What a transcript cell needs from its chat beyond its row: the store and surface for
/// intents (read only inside actions, so a cell never observes the transcript), and the
/// environment the old single-view transcript set on its rows.
@MainActor
final class ChatRowContext {
    let store: AgentChatStore
    let surface: AgentChatSurface
    var openDiff = OpenDiffAction { _, _ in }
    var openFile = OpenFileAction { _, _ in }
    var attachmentLoader = AttachmentLoader { _ in nil }
    var openURL = OpenURLAction { _ in .systemAction }
    /// A tapped disclosure holds its line while it opens or closes (the dock sets it).
    var foldHold = TranscriptFoldHold(begin: {}, end: {})

    init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    /// The agent message's whole text now (a block's Copy and Share take the message).
    func messageText(_ messageID: String) -> String {
        for turn in store.turns.reversed() {
            for case .message(let id, let markdown) in turn.items where id == messageID { return markdown }
        }
        return ""
    }

    /// A user bubble's Edit and Resend: the message goes into the composer to edit and is
    /// sent from there. A draft already in the composer is never replaced without asking.
    func editAndResend(turnID: String) {
        guard let turn = store.turns.last(where: { $0.id == turnID }) else { return }
        if surface.editAndResend(turn, store: store) { return }
        ChatReplaceDraft.present { [self] copyFirst in
            if copyFirst { UIPasteboard.general.string = surface.text }
            surface.loadForEditing(turn.prompt, permissionPending: store.pendingPermission != nil)
        }
    }

    /// The turn's changes when a diff opens (cached, else computed for the tap).
    func changeSet(turnID: String, fallbackID: String) async -> DiffChangeSet {
        guard let turn = store.turns.last(where: { $0.id == turnID }) else {
            return DiffChangeSet(id: fallbackID, title: "Changes", subtitle: "", files: [])
        }
        return await store.diffs.changeSetReady(for: turn) ?? DiffChangeSet(id: fallbackID, title: "Changes", subtitle: "", files: [])
    }
}

/// One transcript row, drawn by the same views the turn layout used.
struct ChatRowView: View {
    let row: ChatRow
    let context: ChatRowContext

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openDiff, context.openDiff)
            .environment(\.openSessionFile, context.openFile)
            .environment(\.attachmentLoader, context.attachmentLoader)
            .environment(\.openURL, context.openURL)
            .environment(\.chatDisclosures, context.surface.disclosures)
            .environment(\.transcriptFoldHold, context.foldHold)
    }

    @ViewBuilder
    private var content: some View {
        let store = context.store
        switch row.kind {
        case .sessionStart(let date, let earlier):
            Text(ChatRow.sessionLine(date, earlier: earlier))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 20)
        case .prompt(let text, let attachments, let at, let isLast):
            let turnID = row.turnID
            UserBubble(prompt: text, attachments: attachments, promptAt: at, isLast: isLast) { context.editAndResend(turnID: turnID) }
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .block(let messageID, let block):
            MarkdownBlockRow(block: block) { context.messageText(messageID) }
        case .thought(let text, let isLive):
            ThoughtRow(text: text, isLive: isLive, id: row.id)
        case .tool(let call):
            ToolRowView(call: call)
        case .toolGroup(let calls, let turnRunning):
            ToolGroupView(calls: calls, turnRunning: turnRunning)
        case .edit(let call, let files):
            if call.isRunning {
                ToolRowView(call: call)
            } else {
                let turnID = row.turnID
                DiffSnippet(call: call, previews: files) { await context.changeSet(turnID: turnID, fallbackID: call.id) }
            }
        case .plan(let entries):
            PlanCard(entries: entries)
        case .permission(let record, let offersChoices):
            let surface = context.surface
            PermissionCard(record: record, agentName: store.summary.agentName,
                           showChoices: offersChoices ? { withAnimation(.cmuxMobileSmooth) { surface.showPermissionChoices() } } : nil)
        case .question(let question):
            VStack(alignment: .leading, spacing: 10) {
                QuestionCard(question: question) { store.answer(question, with: $0) }
                if question.isPending, question.source.rejectOption != nil {
                    // A phone's answer can be refused (only the Mac may answer); a decline always goes through.
                    Button("Decline") { store.decline(question) }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        case .subagents(let ids):
            let surface = context.surface
            SubagentGroupCard(ids: ids, store: store) { surface.parityRoute = .subagent($0) }
        case .working(let label, let since):
            WorkingLabel(label, since: since)
                .frame(minHeight: 28)
        case .editedFiles(let changes):
            EditedFilesCard(changeSet: changes)
        case .stopped:
            Text("Stopped").font(.footnote).foregroundStyle(.tertiary)
        case .failed(_, let errorText):
            let failure = TurnFailureCopy(message: errorText, harness: store.summary.harness, harnessName: store.summary.agentName)
            let turn = store.turns.last { $0.id == row.turnID }
            // The latest failed turn retries through acpmux (its input and context kept).
            FailureCard(title: "Agent stopped", message: failure.sentence, detail: failure.detail,
                        canRetry: turn.map { store.canRetryFailedTurn($0) } ?? false,
                        retryWith: turn.flatMap { RetryModelChoice(store: store, turn: $0) }) {
                if let turn { store.retryFailedTurn(turn) }
            }
        case .actions(let turn, let isLast):
            AnswerActionRow(turn: turn, isLast: isLast, insetsTargets: false, retryWith: RetryModelChoice(store: store, turn: turn)) {
                store.retry(turn)
            }
        }
    }
}

/// One block of an agent message. Copy and Share take the whole message, read when chosen.
struct MarkdownBlockRow: View {
    let block: MarkdownBlock
    let message: () -> String

    var body: some View {
        MarkdownBlockView(block: block, margin: 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message() }
                Button("Share", systemImage: "square.and.arrow.up") { ChatShare.present(message()) }
            }
    }
}

/// Edit and Resend while the composer holds a draft: replace it only on a choice here, and
/// offer to copy it first.
@MainActor
enum ChatReplaceDraft {
    static func present(_ replace: @escaping (_ copyFirst: Bool) -> Void) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let sheet = UIAlertController(title: "Replace your draft?",
                                      message: "Edit and Resend puts this message in the composer.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy Draft and Replace", style: .default) { _ in replace(true) })
        sheet.addAction(UIAlertAction(title: "Replace Draft", style: .destructive) { _ in replace(false) })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}

/// The system share sheet for text, from the key window's top controller.
@MainActor
enum ChatShare {
    static func present(_ text: String) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}
#endif
