import AppKit
import SwiftUI

/// Explicit remote-to-local mappings. Rows receive values and actions only.
struct CloudPortsTable: View {
    let models: [CloudPortAccessModel]
    var allowsStart = true

    var body: some View {
        let rows = models.map { model in
            let host = model.target.host
            let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return (id: model.id, remote: "\(address):\(model.id.port)", local: model.localAddress,
             phase: model.phase, prefersForwarding: model.prefersForwarding,
             start: { model.forward() }, stop: { Task { await model.stop() } })
        }
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text(String(localized: "cloud.ports.remote", defaultValue: "Remote port"))
                Text(String(localized: "cloud.ports.local", defaultValue: "Local address"))
                Text(String(localized: "cloud.ports.status", defaultValue: "Status"))
                Color.clear.frame(width: 1, height: 1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            ForEach(rows, id: \.id) { row in
                let phase = row.phase
                let local = row.local
                GridRow {
                    Text(verbatim: row.remote)
                        .textSelection(.enabled)
                    Text(verbatim: local ?? "—")
                        .monospaced()
                        .textSelection(.enabled)
                    Text(CloudPortAccessText.status(phase))
                    HStack(spacing: 8) {
                        if let local {
                            Button(String(localized: "cloud.ports.copy", defaultValue: "Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://\(local)", forType: .string)
                            }
                            Button(String(localized: "cloud.ports.stop", defaultValue: "Stop Forwarding")) {
                                _ = row.stop()
                            }
                            .accessibilityIdentifier("CloudPortStopForwarding")
                        } else if row.prefersForwarding && phase == .connecting {
                            Button(String(localized: "cloud.vpn.setup.cancel", defaultValue: "Cancel")) { _ = row.stop() }
                        } else if allowsStart {
                            Button(String(localized: "cloud.ports.forward", defaultValue: "Forward Port")) { row.start() }
                                .disabled(phase == .connecting || phase == .stopping || phase == .closed)
                                .accessibilityIdentifier("CloudPortStartForwarding")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("CloudPortsTable")
    }
}
