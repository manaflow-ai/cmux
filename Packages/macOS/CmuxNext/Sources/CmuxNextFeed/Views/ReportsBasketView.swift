import CmuxNextDesign
import SwiftUI

/// Labs dogfood for the no-wake reports target. Agent notices already present
/// in the feed are projected here as a human-only basket; selecting Reply sends
/// a new addressed message through the host callback and never mutates the
/// incoming report.
struct ReportsBasketView: View {
    let model: FeedModel
    let onReply: (@MainActor (String, String) -> Void)?
    @Environment(\.feedColors) private var colors
    @State private var selected: String?
    @State private var draft = ""

    private var reports: [FeedItem] {
        model.visibleItems
            .filter { $0.poster.kind == .agent || $0.poster.kind == .harness }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reports basket").font(.system(size: 15, weight: .semibold))
                        Text("Human view · reports do not wake a model")
                            .font(.system(size: 11)).foregroundStyle(colors.tertiary)
                    }
                    Spacer()
                    Text("LABS").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(colors.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                FeedHairline()
                if reports.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                        Text("No agent reports yet")
                            .font(.system(size: 13))
                        Text("Deliver to reports:<person> to add one without waking a Chief.")
                            .font(.system(size: 11)).foregroundStyle(colors.tertiary)
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
                    onReply?(report.id, text)
                    draft = ""
                })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                    Text("Select a report").font(.system(size: 13))
                }
                .foregroundStyle(colors.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(colors.background)
        .onAppear { selected = selected ?? reports.first?.id }
    }
}

private struct ReportsBasketRow: View {
    let item: FeedItem
    let selected: Bool
    let select: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.down.message").font(.system(size: 12))
                    .foregroundStyle(colors.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.poster.displayLabel).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(item.createdAt, style: .time).font(.system(size: 10))
                            .foregroundStyle(colors.tertiary)
                    }
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary).lineLimit(1)
                    Text(item.body).font(.system(size: 11)).foregroundStyle(colors.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(selected ? colors.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

private struct ReportsBasketDetail: View {
    let item: FeedItem
    @Binding var draft: String
    let onSend: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 16, weight: .semibold))
                Text("From \(item.poster.displayLabel) · \(item.createdAt, style: .date) \(item.createdAt, style: .time)")
                    .font(.system(size: 11)).foregroundStyle(colors.tertiary)
            }
            .padding(18)
            FeedHairline()
            ScrollView {
                Text(item.body.isEmpty ? "(empty report)" : item.body)
                    .font(.system(size: 13)).foregroundStyle(colors.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            Spacer(minLength: 0)
            FeedHairline()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to this sending session…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Reply", action: onSend).buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }
}
