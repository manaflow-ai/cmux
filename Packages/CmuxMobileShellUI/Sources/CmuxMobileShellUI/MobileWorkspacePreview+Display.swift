import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Display-only derivations of ``MobileWorkspacePreview`` used by the workspace
/// list rows (preview line, status color, avatar, timestamp/detail summaries).
extension MobileWorkspacePreview {
    var previewLine: String {
        terminals.first?.name ?? name
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

    func timestampOrStatus(host: String, connectionStatus: MobileMacConnectionStatus) -> String {
        if connectionStatus != .connected {
            return connectionStatus.label
        }
        let date = latestActivityDate
        guard date.timeIntervalSince1970 > 1 else {
            return host.isEmpty ? (terminals.first?.name ?? "") : host
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    func detailLine(host: String, connectionStatus: MobileMacConnectionStatus) -> String {
        let count = L10n.terminalCount(terminals.count)
        guard connectionStatus == .connected else {
            return count
        }
        guard !host.isEmpty else {
            return count
        }
        return "\(host), \(count)"
    }

    func accessibilitySummary(host: String, connectionStatus: MobileMacConnectionStatus) -> String {
        let detail = detailLine(host: host, connectionStatus: connectionStatus)
        // A healthy connection contributes no status text anywhere, including VoiceOver.
        guard connectionStatus != .connected else {
            return "\(previewLine), \(detail)"
        }
        return "\(previewLine), \(connectionStatus.label), \(detail)"
    }

    private var latestActivityDate: Date { .distantPast }

private var stableAvatarSeed: Int {
        id.rawValue.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
    }
}
