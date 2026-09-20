import CmuxFoundation
import SwiftUI

struct CloudTreePlaceholderContent: View {
    let placeholder: CloudTreePlaceholder
    let style: CloudTreeStyle

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
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
        .padding(.trailing, style.rowGrid.trailingPadding)
    }
}
