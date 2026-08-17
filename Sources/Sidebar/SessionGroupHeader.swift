import SwiftUI

/// Snapshot-driven session section header used by the SwiftUI and AppKit sidebar lists.
struct SessionGroupHeader: View, Equatable {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    static func == (lhs: SessionGroupHeader, rhs: SessionGroupHeader) -> Bool {
        lhs.title == rhs.title && lhs.isCollapsed == rhs.isCollapsed
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                onToggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.custom("Inter", size: 10.5).weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(hex: "#777782") ?? .secondary)
            .contentShape(Rectangle())
            .padding(.horizontal, 17)
            .padding(.top, 12)
            .padding(.bottom, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(
            isCollapsed
                ? String(localized: "sidebar.sessionGroup.collapsed", defaultValue: "Collapsed")
                : String(localized: "sidebar.sessionGroup.expanded", defaultValue: "Expanded")
        ))
    }
}
