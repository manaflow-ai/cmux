import CmuxNextDesign
import SwiftUI

/// One report in the Labs reports basket's list: the sender, when it arrived and the first lines of
/// its text. Takes the report as a value (no store below the list's `ForEach`).
struct ReportsBasketRow: View {
    let item: FeedReport
    let selected: Bool
    let select: () -> Void
    @Environment(\.feedColors) private var colors

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "arrow.down.message").font(.system(size: TypeScale.detail))
                    .foregroundStyle(colors.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.sender).font(.system(size: TypeScale.detail, weight: .semibold))
                        Spacer()
                        Text(item.createdAt, style: .time).font(.system(size: TypeScale.caption))
                            .foregroundStyle(colors.tertiary)
                    }
                    Text(item.body).font(.system(size: TypeScale.caption)).foregroundStyle(colors.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(selected ? colors.selection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
