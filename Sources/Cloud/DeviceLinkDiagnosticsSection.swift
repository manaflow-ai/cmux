import CmuxCloud
import SwiftUI

/// The My Devices part of the Cloud Diagnostics window: every device link's
/// recent state changes, newest first, with the failure class and code that
/// the copied report carries.
struct DeviceLinkDiagnosticsSection: View {
    let diagnostics: DeviceLinkDiagnostics

    private static let shownEvents = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "devices.diagnostics.title", defaultValue: "My Devices"))
                .font(.subheadline.bold())
            if diagnostics.events.isEmpty {
                Text(String(localized: "devices.diagnostics.empty", defaultValue: "No device link activity recorded in this session."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(diagnostics.events.suffix(Self.shownEvents).reversed()) { event in
                HStack(alignment: .top) {
                    Image(systemName: Self.symbol(for: event))
                        .foregroundStyle(event.relevantFailure == nil ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        // The attempt is a technical ordinal, shown as a bare number after the localized phase.
                        Text(verbatim: [event.deviceName, Self.phaseLabel(event), event.attempt.map { "#\($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                        if let failure = event.relevantFailure {
                            Text(failure.message).foregroundStyle(.orange)
                            Text("\(failure.kind.rawValue) \u{00B7} \(failure.code)").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(event.at, style: .time).foregroundStyle(.secondary)
                }
                .font(.caption)
                .cloudErrorCopyMenu(event.relevantFailure == nil ? nil : event.reportLine)
            }
            if let path = diagnostics.journalPath {
                Text(String(format: String(localized: "devices.diagnostics.journal", defaultValue: "Full link journal: %@"), path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private static func symbol(for event: DeviceLinkDiagnosticEvent) -> String {
        switch event.phase {
        case .connected: return "checkmark"
        case .connecting, .waiting: return "clock"
        case .blocked: return "exclamationmark.triangle"
        case .idle: return "minus"
        }
    }

    static func phaseLabel(_ event: DeviceLinkDiagnosticEvent) -> String {
        switch event.phase {
        case .idle:
            return String(localized: "devices.diagnostics.phase.idle", defaultValue: "Idle")
        case .connecting:
            return String(localized: "devices.diagnostics.phase.connecting", defaultValue: "Connecting")
        case .connected:
            return String(localized: "devices.diagnostics.phase.connected", defaultValue: "Connected")
        case .waiting:
            return String(localized: "devices.diagnostics.phase.waiting", defaultValue: "Waiting to retry")
        case .blocked:
            return String(localized: "devices.diagnostics.phase.blocked", defaultValue: "Stopped")
        }
    }
}
