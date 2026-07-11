import CmuxAndroidEmulator
import SwiftUI

/// Value-only row for one Android Virtual Device.
struct AndroidEmulatorDeviceRow: View {
    let device: AndroidVirtualDevice
    let isLaunching: Bool
    let isStopping: Bool
    let onLaunch: () -> Void
    let onStop: (String, String) -> Void
    let onOpenInPane: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.state.isRunning ? "play.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(device.state.isRunning ? Color.green : Color.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isLaunching || isStopping {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(statusText)
            } else {
                switch device.state {
                case .stopped:
                    Button(String(localized: "androidEmulator.action.launch", defaultValue: "Launch", bundle: .module)) {
                        onLaunch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .running(let serial, _, let transportID):
                    HStack(spacing: 6) {
                        Button(String(
                            localized: "androidEmulator.action.openInPane",
                            defaultValue: "Open",
                            bundle: .module
                        )) {
                            onOpenInPane()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button(String(localized: "androidEmulator.action.stop", defaultValue: "Stop", bundle: .module)) {
                            onStop(serial, transportID)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .unavailable:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if isLaunching {
            return String(localized: "androidEmulator.status.launching", defaultValue: "Launching…", bundle: .module)
        }
        if isStopping {
            return String(localized: "androidEmulator.status.stopping", defaultValue: "Stopping…", bundle: .module)
        }
        switch device.state {
        case .stopped:
            return String(localized: "androidEmulator.status.stopped", defaultValue: "Stopped", bundle: .module)
        case .unavailable:
            return String(
                localized: "androidEmulator.status.unavailable",
                defaultValue: "State unavailable",
                bundle: .module
            )
        case .running(let serial, let connectionState, _):
            let format = String(
                localized: "androidEmulator.status.running",
                defaultValue: "Running · %@ · %@",
                bundle: .module
            )
            return String(format: format, serial, connectionState)
        }
    }
}
