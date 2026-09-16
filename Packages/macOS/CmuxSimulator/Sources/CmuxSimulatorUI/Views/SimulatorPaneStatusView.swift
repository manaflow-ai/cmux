import CmuxSimulator
import SwiftUI

struct SimulatorPaneStatusView: View {
    let status: SimulatorSessionStatus
    let isDiscoveringDevices: Bool
    let recover: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(indicatorColor)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(title))
            if needsRecovery {
                Button(action: recover) { Text(simulatorStrings.reconnect) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private var title: LocalizedStringResource {
        if isDiscoveringDevices { return simulatorStrings.findingDevices }
        return switch status {
        case .idle: simulatorStrings.selectToStart
        case .connecting: simulatorStrings.connecting
        case .streaming: simulatorStrings.streaming
        case .deviceUnavailable: simulatorStrings.unavailable
        case .workerCrashed: simulatorStrings.workerStopped
        case .failed: simulatorStrings.failed
        }
    }

    private var needsRecovery: Bool {
        switch status {
        case .deviceUnavailable, .workerCrashed, .failed: true
        case .idle, .connecting, .streaming: false
        }
    }

    private var symbol: String {
        if isDiscoveringDevices { return "magnifyingglass" }
        switch status {
        case .idle: return "circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .streaming: return "circle.fill"
        case .deviceUnavailable, .workerCrashed, .failed: return "exclamationmark.triangle"
        }
    }

    private var indicatorColor: Color {
        if isDiscoveringDevices { return .secondary }
        if needsRecovery { return .orange }
        return status == .streaming ? .green : .secondary
    }
}
