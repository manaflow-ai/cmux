import CmuxMobileShellModel
import CmuxMobileSupport
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
    /// otherwise the compact relative activity time. `now` is threaded from the
    /// row's `TimelineView` so the label refreshes as time passes and stays
    /// deterministic in tests.
    func timestampOrStatus(connectionStatus: MobileMacConnectionStatus, now: Date) -> String {
        if connectionStatus != .connected {
            return connectionStatus.label
        }
        return relativeActivityLabel(now: now)
    }

    /// Compact relative time for the row's trailing slot, like a messaging list:
    /// "now" under a minute, then "2m", "1h", "3d", and a localized month/day
    /// past a week. Empty when there is no real activity timestamp. The bucket
    /// and its count come from ``MobileRelativeActivity``, computed purely from
    /// the injected `now`, so the label is deterministic in tests (only the
    /// `monthDay` case formats the date itself, which does not depend on `now`).
    func relativeActivityLabel(now: Date) -> String {
        let date = latestActivityDate
        switch MobileRelativeActivity.bucket(for: date, now: now) {
        case .none:
            // The trailing slot stays empty rather than echoing the epoch.
            return ""
        case .now:
            return L10n.string("mobile.workspace.preview.justNow", defaultValue: "now")
        case .minutes(let minutes):
            return String(
                format: L10n.string("mobile.workspace.preview.minutesCompactFormat", defaultValue: "%dm"),
                minutes
            )
        case .hours(let hours):
            return String(
                format: L10n.string("mobile.workspace.preview.hoursCompactFormat", defaultValue: "%dh"),
                hours
            )
        case .days(let days):
            return String(
                format: L10n.string("mobile.workspace.preview.daysCompactFormat", defaultValue: "%dd"),
                days
            )
        case .monthDay:
            // Past a week, a month/day date is more useful than "5 weeks ago".
            return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        }
    }

    func detailLine(connectionStatus: MobileMacConnectionStatus) -> String {
        // The connected row shows only the terminal count; the host Mac name
        // lives in Settings and the disconnected status row, never the row body.
        L10n.terminalCount(terminals.count)
    }

    func accessibilitySummary(connectionStatus: MobileMacConnectionStatus) -> String {
        let detail = detailLine(connectionStatus: connectionStatus)
        // A healthy connection contributes no status text anywhere, including VoiceOver.
        guard connectionStatus != .connected else {
            return "\(previewLine), \(detail)"
        }
        return "\(previewLine), \(connectionStatus.label), \(detail)"
    }

    private var latestActivityDate: Date { previewAt ?? .distantPast }

    private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}
