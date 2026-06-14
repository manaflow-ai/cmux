import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Display-only derivations of ``MobileWorkspacePreview`` used by the workspace
/// list rows (preview line, status color, avatar, timestamp/detail summaries).
extension MobileWorkspacePreview {
    var previewLine: String {
        // Prefer the Mac's last-activity preview (latest notification text). Fall
        // back to the first terminal's name (or the workspace name) when the Mac
        // has no activity to preview or is old enough not to emit one.
        if let previewText, !previewText.isEmpty {
            return previewText
        }
        return terminals.first?.name ?? name
    }

    func statusColor(connectionStatus: MobileMacConnectionStatus) -> Color {
        switch connectionStatus {
        case .connected:
            return terminals.isEmpty ? .orange : .green
        case .reconnecting:
            return .orange
        case .unavailable:
            return .red
        }
    }

    var avatarSymbolName: String {
        terminals.count > 1 ? "rectangle.stack.fill" : "terminal.fill"
    }

    var avatarGradient: LinearGradient {
        let palettes: [[Color]] = [
            [Color.blue, Color.cyan],
            [Color.green, Color.teal],
            [Color.orange, Color.yellow],
            [Color.gray, Color.blue],
        ]
        let colors = palettes[abs(stableAvatarSeed) % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The row's trailing slot: the connection problem when there is one,
    /// otherwise a static activity timestamp. This intentionally avoids a live
    /// relative clock in list rows so native swipe tracking is not invalidated by
    /// timer-driven row updates.
    func timestampOrStatus(connectionStatus: MobileMacConnectionStatus) -> String {
        if connectionStatus != .connected {
            return connectionStatus.label
        }
        return activityTimestampLabel()
    }

    /// Static timestamp for the row's trailing slot. Recent activity shows the
    /// local time; older activity shows a compact month/day. Empty when there is
    /// no real activity timestamp.
    func activityTimestampLabel(referenceDate: Date = .now, calendar: Calendar = .current) -> String {
        let date = latestActivityDate
        guard date > Date(timeIntervalSince1970: 1) else {
            return ""
        }
        if calendar.isDate(date, inSameDayAs: referenceDate) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    func detailLine(connectionStatus: MobileMacConnectionStatus) -> String {
        // The connected row shows only the terminal count; the host Mac name
        // lives in Settings and the disconnected status row, never the row body.
        L10n.terminalCount(terminals.count)
    }

    func accessibilitySummary(connectionStatus: MobileMacConnectionStatus) -> String {
        var parts: [String] = []
        // The unread dot itself is accessibility-hidden; VoiceOver hears the
        // state here instead, leading like Messages does.
        if hasUnread {
            parts.append(L10n.string("mobile.workspace.unread", defaultValue: "Unread"))
        }
        parts.append(previewLine)
        // A healthy connection contributes no status text anywhere, including VoiceOver.
        if connectionStatus != .connected {
            parts.append(connectionStatus.label)
        }
        parts.append(detailLine(connectionStatus: connectionStatus))
        return parts.joined(separator: ", ")
    }

    /// The instant the row's relative time renders. Prefers the Mac's
    /// every-row `last_activity_at` stamp; falls back to the preview timestamp
    /// for Macs that emit previews but predate the stamp, then to
    /// `.distantPast` (which buckets to `.none`, an empty trailing slot).
    private var latestActivityDate: Date { lastActivityAt ?? previewAt ?? .distantPast }

    private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}
