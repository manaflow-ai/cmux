import Foundation
import SwiftUI

/// Breadcrumb / back affordance shown at the top of the sidebar while drilled
/// into a workstream. Tapping "Workstreams" (or the back chevron) returns to
/// the top-level master list; the trailing segment names the current
/// workstream. Holds no store reference — value snapshot + one closure.
struct SidebarWorkstreamBreadcrumbView: View, Equatable {
    nonisolated static func == (lhs: SidebarWorkstreamBreadcrumbView, rhs: SidebarWorkstreamBreadcrumbView) -> Bool {
        lhs.workstreamName == rhs.workstreamName &&
            lhs.workspaceCount == rhs.workspaceCount &&
            lhs.fontScale == rhs.fontScale
    }

    let workstreamName: String
    let workspaceCount: Int
    let fontScale: CGFloat
    let onBack: () -> Void

    private var rootLabel: String {
        String(localized: "workstream.breadcrumb.root", defaultValue: "Workstreams")
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11 * fontScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(rootLabel)
                .font(.system(size: 12 * fontScale, weight: .medium))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9 * fontScale, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(workstreamName)
                .font(.system(size: 12 * fontScale, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(workspaceCount)")
                .font(.system(size: 11 * fontScale, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onBack() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(String.localizedStringWithFormat(
            String(
                localized: "workstream.breadcrumb.a11y",
                defaultValue: "Back to workstreams. Currently in %@."
            ),
            workstreamName
        )))
        .accessibilityIdentifier("sidebarWorkstreamBreadcrumb")
    }
}
