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

    /// The transcript's hold of a tapped disclosure's line, set by the list
    /// (`ChatTranscriptList.beginHold`, `ChatTranscriptController.holdForDisclosure(row:)`).
    var beginFold: (String) -> Void = { _ in }
    var endFold: () -> Void = {}

    init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
    }

    /// Row `rowID`'s `transcriptFoldHold`: a disclosure tapped in it holds that row's line.
    func foldHold(_ rowID: String) -> TranscriptFoldHold {
        TranscriptFoldHold(begin: { [weak self] in self?.beginFold(rowID) }, end: { [weak self] in self?.endFold() })
    }

    /// A disclosure tap on row `rowID` from its native line (or the list rig): the same hold and
    /// spring as the SwiftUI row's own button (`toggleDisclosure`).
    func toggleFold(row rowID: String, key: String, open: Bool) {
        let disclosures = surface.disclosures
        toggleDisclosure(foldHold(rowID)) { disclosures.set(key, open) }
    }

    /// The agent message's whole text now (a block's Copy and Share take the message).
    func messageText(_ messageID: String) -> String {
        for turn in store.turns.reversed() {
            for case .message(let id, let markdown) in turn.items where id == messageID { return markdown }
        }
        return ""
    }

    /// The turn's changes when a diff opens (cached, else computed for the tap).
    func changeSet(turnID: String, fallbackID: String) -> DiffChangeSet {
        guard let turn = store.turns.last(where: { $0.id == turnID }) else {
            return DiffChangeSet(id: fallbackID, title: "Changes", subtitle: "", files: [])
        }
        return store.diffs.changeSetNow(for: turn) ?? DiffChangeSet(id: fallbackID, title: "Changes", subtitle: "", files: [])
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
            .environment(\.transcriptFoldHold, context.foldHold(row.id))
    }

    @ViewBuilder
    private var content: some View {
        let store = context.store
        switch row.kind {
        case .sessionStart(let date, let earlierHistory):
            // A chat opened on its newest history says where what is shown starts.
            Text(ChatRow.sessionLine(date, earlierHistory: earlierHistory))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 20)
        case .prompt(let text, let attachments, let at, let isLast):
            let surface = context.surface
            let turnID = row.turnID
            UserBubble(prompt: text, attachments: attachments, promptAt: at, isLast: isLast) {
                if let turn = store.turns.last(where: { $0.id == turnID }) { surface.editAndResendOrAsk(turn, store: store) }
            }
                .findBlock(row.findKey, surface: surface, reportsFrame: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .block(let messageID, let block):
            MarkdownBlockRow(block: block, findKey: row.findKey, surface: context.surface) { context.messageText(messageID) }
        case .thought(let text, let isLive):
            ThoughtRow(text: text, isLive: isLive, id: row.id).foldableRow()
        case .tool(let call):
            ToolRowView(call: call).foldableRow()
        case .toolGroup(let calls, let turnRunning):
            ToolGroupView(calls: calls, turnRunning: turnRunning).foldableRow()
        case .edit(let call, let files):
            if call.isRunning {
                ToolRowView(call: call).foldableRow()
            } else {
                let turnID = row.turnID
                DiffSnippet(call: call, previews: files) { context.changeSet(turnID: turnID, fallbackID: call.id) }
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
        case .failed(let turn, let canRetry):
            let failure = TurnFailureCopy(message: turn.errorText, harness: store.summary.harness, harnessName: store.summary.agentName)
            FailureCard(title: "Agent stopped", message: failure.sentence, detail: failure.detail,
                        canRetry: canRetry,
                        retryWith: RetryModelChoice(store: store, turn: turn)) {
                store.retryFailedTurn(turn)
            }
        case .actions(let turn, let isLast):
            AnswerActionRow(turn: turn, isLast: isLast, insetsTargets: false, retryWith: RetryModelChoice(store: store, turn: turn)) {
                store.retry(turn)
            }
        }
    }
}

extension View {
    /// A row with a disclosure: its own height from the cell's top, however tall the cell is
    /// drawn while the disclosure opens or closes (`ChatRowCell.folding`). At rest the cell is that
    /// height, so nothing changes; measured, it is the row's ideal height either way.
    func foldableRow() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One block of an agent message. Copy and Share take the whole message, read when chosen.
struct MarkdownBlockRow: View {
    let block: MarkdownBlock
    /// Find in Chat's key for this block (`AgentChatFind.blockKey`); nil outside a transcript.
    var findKey: String?
    var surface: AgentChatSurface?
    let message: () -> String

    var body: some View {
        MarkdownBlockView(block: block, margin: 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .findBlock(findKey, surface: surface, reportsFrame: false)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message() }
                Button("Share", systemImage: "square.and.arrow.up") { ChatShare.present(message()) }
            }
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
