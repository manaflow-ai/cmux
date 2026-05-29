import SwiftUI

struct WorkspaceInsightRow: View {
    var insight: WorkspaceInsight
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: insight.isSelected ? "target" : "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(insight.isSelected ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(insight.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !insight.subtitle.isEmpty {
                        Text(insight.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    signalLine
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(insight.isSelected ? Color.blue.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var signalLine: some View {
        HStack(spacing: 5) {
            if insight.unreadCount > 0 {
                Label("\(insight.unreadCount)", systemImage: "bell.badge")
            }
            if insight.portCount > 0 {
                Label("\(insight.portCount)", systemImage: "network")
            }
            if insight.pullRequestCount > 0 {
                Label("\(insight.pullRequestCount)", systemImage: "arrow.triangle.pull")
            }
            if let branch = insight.branch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.branch")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}
