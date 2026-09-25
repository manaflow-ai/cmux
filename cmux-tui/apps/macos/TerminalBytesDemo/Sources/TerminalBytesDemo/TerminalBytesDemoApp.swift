import AppKit
import SwiftUI

final class TerminalBytesDemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }
}

@main
struct TerminalBytesDemoApp: App {
    @NSApplicationDelegateAdaptor(TerminalBytesDemoAppDelegate.self)
    private var appDelegate
    @State private var model = TerminalModel()

    var body: some Scene {
        Window(L10n.text("app.title", "TerminalBytes Demo"), id: "terminal-bytes-demo") {
            ContentView(model: model)
                .frame(minWidth: 780, minHeight: 520)
                .onDisappear {
                    model.shutdown()
                }
        }
    }
}

struct ContentView: View {
    @Bindable var model: TerminalModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SecureField(
                    L10n.text("field.invitation", "Enrollment invitation"),
                    text: $model.invitation
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    L10n.text("field.terminal", "Terminal ID"),
                    text: $model.terminalID
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                if model.isConnected {
                    Button(L10n.text("button.disconnect", "Disconnect")) {
                        model.disconnect()
                    }
                } else {
                    Button(
                        model.isConnecting
                            ? L10n.text("button.connecting", "Connecting…")
                            : L10n.text("button.connect", "Connect")
                    ) {
                        model.connect()
                    }
                    .disabled(model.isConnecting)
                }
            }
            .padding(10)

            if !model.errorMessage.isEmpty {
                Text(model.errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            TerminalView(
                text: model.frameUpdate,
                dirtyRows: model.dirtyRows,
                dirtyRowText: model.dirtyRowText,
                rowCount: model.rowCount,
                inputReady: model.isConnected,
                submit: model.submit,
                resize: model.resize
            )
            .background(.black)

            HStack(spacing: 8) {
                Text(L10n.text("diagnostics.title", "Diagnostics"))
                    .fontWeight(.semibold)
                Text(
                    model.diagnostics.isEmpty
                        ? L10n.text("diagnostics.disconnected", "Disconnected")
                        : model.diagnostics
                )
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(L10n.text("diagnostics.copy", "Copy Diagnostics")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnostics, forType: .string)
                }
                .disabled(model.diagnostics.isEmpty)
            }
            .padding(8)
            .background(.bar)
        }
        .task {
            model.connectIfConfigured()
        }
    }
}
