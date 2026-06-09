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

    func timestampOrStatus(connectionStatus: MobileMacConnectionStatus) -> String {
        if connectionStatus != .connected {
            return connectionStatus.label
        }
        return relativeActivityLabel(now: Date())
    }

    /// Compact relative time for the row's trailing slot, like a messaging list:
    /// "now" under a minute, otherwise an abbreviated localized relative time
    /// ("2m", "1h", "3d"). Falls back to a localized month/day for older activity
    /// and an empty string when there is no real activity timestamp. `now` is
    /// injected so the formatting is deterministic in tests.
    func relativeActivityLabel(now: Date) -> String {
        let date = latestActivityDate
        // Without a real activity timestamp the trailing slot stays empty rather
        // than echoing the Mac.
        guard date.timeIntervalSince1970 > 1 else {
            return ""
        }
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return L10n.string("mobile.workspace.preview.justNow", defaultValue: "now")
        }
        // Within a week, an abbreviated relative time reads like iMessage. Past a
        // week, a month/day date is more useful than "5 weeks ago".
        if interval < 7 * 24 * 60 * 60 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
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
