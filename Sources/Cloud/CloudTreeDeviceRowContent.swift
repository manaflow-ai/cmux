import SwiftUI

/// Another Mac's row in the shared tree.
///
/// Devices follow the same information hierarchy as the iOS Computers list:
/// a small platform avatar, the computer name, a primary connection line, and
/// one quiet diagnostic line. The row deliberately has one presentation on
/// macOS instead of inheriting all of the Cloud tree's visual presets; a
/// computer is a destination, not a VM status card.
struct CloudTreeDeviceRowContent: View {
    let row: CloudTreeDeviceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    /// Injected so rows never read the wall clock in `body` on their own.
    var now: Date = Date()

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .cmuxFont(size: 13, weight: .medium)
                        .foregroundStyle(row.isOnline ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let buildLabel = row.presence?.buildLabel {
                        Text(buildLabel)
                            .cmuxFont(size: 9, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                Text(Self.subtitle(row, now: now))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if Self.showsResourceSummary(row) {
                    Text(Self.resourceSummary(row))
                        .cmuxFont(size: 10)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            presenceGlyph
        }
        .padding(.vertical, 5)
        .padding(.trailing, CloudTreeRowGrid.trailingPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(row.isOnline ? 0.85 : 0.35))
                .frame(width: 28, height: 28)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        "\(row.name), \(Self.subtitle(row, now: now))"
    }

    /// A filled dot for a live device, a hollow one while its link is being
    /// made, a dim dot when offline, and the warning color when the link failed.
    @ViewBuilder
    private var presenceGlyph: some View {
        switch row.indicator {
        case .online:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.online", defaultValue: "Online"))
        case .connecting:
            Circle()
                .strokeBorder(Color.green, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.connecting", defaultValue: "Connecting"))
        case .attention:
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.attention", defaultValue: "Needs attention"))
        case .offline:
            Circle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .help(String(localized: "cloudTree.device.presence.offline", defaultValue: "Offline"))
        }
    }

    /// Outline height for the two-line row (avatar, name, status) and for the
    /// three-line row that adds the resource summary. Both rules live next to
    /// the row body so the view and `heightOfRowByItem` cannot drift apart.
    static let rowHeight: CGFloat = 48
    static let rowHeightWithResourceSummary: CGFloat = 60

    /// Only an online Mac with something to open shows the third line.
    static func showsResourceSummary(_ row: CloudTreeDeviceRow) -> Bool {
        row.isOnline && (row.workspaceCount > 0 || row.terminalCount > 0)
    }

    static func rowHeight(for row: CloudTreeDeviceRow) -> CGFloat {
        showsResourceSummary(row) ? rowHeightWithResourceSummary : rowHeight
    }

    /// The primary connection/presence line. Resource counts are rendered on a
    /// separate line so the status remains easy to scan, matching iOS.
    static func subtitle(_ row: CloudTreeDeviceRow, now: Date) -> String {
        row.statusLabel(now: now)
    }

    static func resourceSummary(_ row: CloudTreeDeviceRow) -> String {
        var parts: [String] = []
        if row.workspaceCount > 0 {
            parts.append(
                row.workspaceCount == 1
                    ? String(localized: "cloudTree.device.workspaceCount.one", defaultValue: "1 workspace")
                    : String(format: String(localized: "cloudTree.device.workspaceCount.other", defaultValue: "%d workspaces"), row.workspaceCount)
            )
        }
        if row.terminalCount > 0 {
            parts.append(CloudTreeRowContentView.count(row.terminalCount))
        }
        return parts.joined(separator: " · ")
    }
}
