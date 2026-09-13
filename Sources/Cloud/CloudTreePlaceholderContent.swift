import SwiftUI

struct CloudTreePlaceholderContent: View {
    let placeholder: CloudTreePlaceholder
    let style: CloudTreeStyle

    var body: some View {
        HStack(alignment: .center, spacing: style.iconGap) {
            Group {
                switch placeholder.style {
                case .connecting:
                    ProgressView().controlSize(.mini)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: max(style.iconSize, 9), weight: .regular))
                        .foregroundStyle(.secondary)
                case .dimmed:
                    Image(systemName: "moon.zzz")
                        .font(.system(size: max(style.iconSize, 9), weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: max(style.iconSlot, 12))
            Text(placeholder.text)
                .cmuxFont(size: style.detailSize + 1, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
    }
}
