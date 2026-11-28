import SwiftUI

struct WorkspaceInsightRow: View {
    var insight: WorkspaceInsight
    var action: () -> Void
    var surfaceAction: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                rowHeader
            }
            .buttonStyle(.plain)

            surfaceStrip
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(insight.isSelected ? Color.blue.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var rowHeader: some View {
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
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var surfaceStrip: some View {
        if !insight.surfaces.isEmpty {
            HStack(spacing: 4) {
                ForEach(insight.surfaces.prefix(4)) { surface in
                    Button {
                        surfaceAction(surface.id)
                    } label: {
                        Image(systemName: surface.iconName)
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 18, height: 16)
                            .foregroundStyle(surface.isFocused ? .blue : .secondary)
                            .background(
                                surface.isFocused ? Color.blue.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.8),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(surface.title)
                }
                if insight.surfaces.count > 4 {
                    Text("+\(insight.surfaces.count - 4)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
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
