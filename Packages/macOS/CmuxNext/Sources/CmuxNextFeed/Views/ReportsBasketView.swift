import CmuxNextDesign
import SwiftUI

/// Labs dogfood for the no-wake reports target. Durable mailbox rows are
/// projected here as a human-only basket; selecting Reply sends a new
/// addressed message through the host callback and never mutates the report.
struct ReportsBasketView: View {
    let model: FeedModel
    let onReply: (@MainActor (String, String) -> Bool)?
    @Environment(\.feedColors) private var colors
    @State private var selected: String?
    @State private var draft = ""

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
                ReportsBasketDetail(item: report, draft: $draft, onSend: {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if onReply?(report.sender, text) == true { draft = "" }
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
