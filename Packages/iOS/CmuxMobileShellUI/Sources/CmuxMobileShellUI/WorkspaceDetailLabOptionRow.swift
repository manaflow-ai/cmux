#if os(iOS) && DEBUG
import SwiftUI

/// Immutable CMUX Labs row for one workspace-detail redesign.
struct WorkspaceDetailLabOptionRow: View {
    let number: Int?
    let title: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0.09))
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .topLeading) {
                    if let number {
                        Text(verbatim: "\(number)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: -6, y: -6)
                    }
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
