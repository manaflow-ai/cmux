import AppKit
import SwiftUI

/// Settings pane for the HTTP control transport.
///
/// Renders the ``HTTPControlSettingsViewModel`` knobs in a SwiftUI
/// ``Form`` and surfaces the two spec-mandated safety warnings:
///
/// * ``HTTPControlSettingsViewModel/tcpSafetyWarning`` whenever the
///   transport picker is on ``HTTPControlSettings/Transport/tcp`` AND
///   the listener is enabled. (Spec §5.4 — the TCP listener has no
///   peer-credential check; any local process holding the token has
///   full shell access.)
/// * ``HTTPControlSettingsViewModel/rawInputWarning`` whenever
///   ``allowRawInput`` is true. (Spec §8.3 — `type=raw` enables OSC 52
///   clipboard ops and DSR / DECRQSS reflection-injection.)
///
/// Token rotation goes through the view model's ``rotateToken()`` so
/// the lifecycle wire-up (Task 1.22) can restart the listener and
/// drop existing connections in the same action.
public struct HTTPControlSettingsView: View {
    @ObservedObject var model: HTTPControlSettingsViewModel
    @State private var token: String = ""

    public init(model: HTTPControlSettingsViewModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Toggle(
                String(
                    localized: "httpControl.enabled",
                    defaultValue: "Enable local HTTP control"
                ),
                isOn: $model.enabled
            )
            Picker(
                String(
                    localized: "httpControl.transport",
                    defaultValue: "Transport"
                ),
                selection: $model.transport
            ) {
                Text(String(
                    localized: "httpControl.transport.tcp",
                    defaultValue: "TCP (127.0.0.1)"
                ))
                .tag(HTTPControlSettings.Transport.tcp)
                Text(String(
                    localized: "httpControl.transport.uds",
                    defaultValue: "Unix domain socket (recommended)"
                ))
                .tag(HTTPControlSettings.Transport.uds)
            }
            if model.enabled && model.transport == .tcp {
                Text(model.tcpSafetyWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Stepper(value: $model.tcpPort, in: 1024...65535) {
                Text(String(
                    localized: "httpControl.port",
                    defaultValue: "TCP port: \(model.tcpPort)"
                ))
            }
            TextField(
                String(
                    localized: "httpControl.uds",
                    defaultValue: "UDS path"
                ),
                text: $model.udsPath
            )
            Toggle(
                String(
                    localized: "httpControl.allowRaw",
                    defaultValue: "Allow type=raw input"
                ),
                isOn: $model.allowRawInput
            )
            if model.allowRawInput {
                Text(model.rawInputWarning)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(
                    token.isEmpty
                        ? String(
                            localized: "httpControl.tokenPlaceholder",
                            defaultValue: "(token not loaded)"
                        )
                        : token
                )
                .textSelection(.enabled)
                Button(String(
                    localized: "httpControl.copy",
                    defaultValue: "Copy"
                )) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                }
                .disabled(token.isEmpty)
                Button(String(
                    localized: "httpControl.rotate",
                    defaultValue: "Rotate"
                )) {
                    if let t = try? model.rotateToken() { token = t }
                }
            }
            TextField(
                String(
                    localized: "httpControl.audit",
                    defaultValue: "Audit log path"
                ),
                text: $model.auditLogPath
            )
        }
        .onAppear { token = (try? model.currentToken()) ?? "" }
        .onDisappear { try? model.commit() }
    }
}
