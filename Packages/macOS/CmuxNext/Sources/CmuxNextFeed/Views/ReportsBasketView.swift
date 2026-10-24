import CmuxNextDesign
import SwiftUI

/// Labs dogfood for the no-wake reports target. Durable mailbox rows are
/// projected here as a human-only basket; selecting Reply sends a new
/// addressed message through the host callback and never mutates the report.
struct ReportsBasketView: View {
    let model: FeedModel
    let onReply: (@MainActor (ReportReply) async -> Bool)?
    @Environment(\.feedColors) private var colors
    @State private var selected: String?
    @State private var draft = ""
    /// Reports whose reply is being sent: their Reply button waits for the answer, so a second
    /// press or key repeat cannot send the same reply twice.
    @State private var sending: Set<String> = []
    /// The report whose last reply was not sent (its draft stays).
    @State private var notSent: String?
    /// Each report's last reply that was not sent: the same reply sent again keeps its id, so a
    /// send that passed its deadline after acpmux queued it is not delivered twice.
    @State private var unsent: [String: ReportReply] = [:]

    private var reports: [FeedReport] { model.reports }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FeedStrings.reportsTitle).font(.system(size: TypeScale.title, weight: .semibold))
                        Text(FeedStrings.reportsSubtitle)
                            .font(.system(size: TypeScale.caption)).foregroundStyle(colors.tertiary)
                    }
                    Spacer()
                    Text(FeedStrings.reportsLabs).font(.system(size: TypeScale.caption, weight: .semibold, design: .rounded))
                        .foregroundStyle(colors.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                FeedHairline()
                if reports.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                        Text(FeedStrings.reportsEmpty)
                            .font(.system(size: TypeScale.body))
                        Text(FeedStrings.reportsEmptyHint)
                            .font(.system(size: TypeScale.caption)).foregroundStyle(colors.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(colors.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(reports) { report in
                                ReportsBasketRow(item: report, selected: selected == report.id) {
                                    selected = report.id
                                    draft = ""
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
            FeedHairline(vertical: true)
            if let report = reports.first(where: { $0.id == selected }) {
                ReportsBasketDetail(item: report, draft: $draft, sending: sending.contains(report.id),
                                    notSent: notSent == report.id, onSend: {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = report.id
                    guard !text.isEmpty, let onReply, !sending.contains(id) else { return }
                    let reply = ReportReply(session: report.sender, text: text, retrying: unsent[id])
                    sending.insert(id)
                    notSent = nil
                    // The host sends off the main thread and answers once acpmux took the reply (or
                    // refused, or passed its deadline). A sent reply clears the draft unless the
                    // person typed on or chose another report; a refused one keeps it.
                    // task-owner: one reply send; it ends when the host answers (bounded by its deadline)
                    Task { @MainActor in
                        let sent = await onReply(reply)
                        sending.remove(id)
                        if !sent {
                            notSent = id
                            unsent[id] = reply
                        } else {
                            unsent[id] = nil
                            if selected == id, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
                        }
                    }
                })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                    Text(FeedStrings.reportsSelect).font(.system(size: TypeScale.body))
                }
                .foregroundStyle(colors.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(colors.background)
        .onAppear { selected = selected ?? reports.first?.id }
    }
}
