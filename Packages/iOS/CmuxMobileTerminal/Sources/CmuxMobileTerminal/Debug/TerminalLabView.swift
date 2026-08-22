#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import SwiftUI
import UIKit

/// Terminal Lab: DEBUG-only dogfood screen for the terminal-lab snapshot/tail
/// protocol (termd). Connects over raw TCP to a termd on the paired Mac and
/// renders the session through the REAL production `GhosttySurfaceView`, so
/// typing, the accessory bar, zoom, and scrollback behave exactly like the
/// production terminal while the transport is the lab's generation-indexed
/// attach protocol.
///
/// Mac side (from a cmuxterm-hq checkout, PR 318):
///   terminal-lab/daemon/.build/release/termd \
///     --host <tailscale-ip> --port 7681 --token <secret>
///
/// Reachable from Settings > Developer > Terminal Lab, or at the root with
/// CMUX_TERMINAL_LAB=1. Scripted preflight can pre-fill and auto-connect with
/// CMUX_TERMINAL_LAB_HOST / _PORT / _TOKEN / _AUTOCONNECT=1.
public struct TerminalLabView: View {
    @AppStorage("cmux.debug.terminalLab.host") private var host = ""
    @AppStorage("cmux.debug.terminalLab.port") private var portText = "7681"
    @AppStorage("cmux.debug.terminalLab.token") private var token = ""
    @State private var client: TerminalLabClient?
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let client {
                TerminalLabStatusBar(client: client)
                Divider()
                TerminalLabSurface(client: client)
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "terminal",
                    description: Text("Start termd on the Mac, enter its host, port, and token, then Connect.")
                )
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear(perform: applyEnvironmentOverrides)
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain)
            TextField("host", text: $host)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("port", text: $portText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .frame(width: 64)
            SecureField("token", text: $token)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            Button(client == nil ? "Connect" : "Disconnect") {
                if client == nil { connect() } else { disconnect() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(client == nil && (host.isEmpty || UInt16(portText) == nil))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func connect() {
        guard let port = UInt16(portText), !host.isEmpty else { return }
        client = TerminalLabClient(host: host, port: port, token: token)
    }

    private func disconnect() {
        client?.stop()
        client = nil
    }

    /// Scripted-launch overrides for tagged sim preflights: environment wins
    /// over the persisted fields, and autoconnect skips the manual tap.
    private func applyEnvironmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let h = env["CMUX_TERMINAL_LAB_HOST"], !h.isEmpty { host = h }
        if let p = env["CMUX_TERMINAL_LAB_PORT"], UInt16(p) != nil { portText = p }
        if let t = env["CMUX_TERMINAL_LAB_TOKEN"] { token = t }
        if env["CMUX_TERMINAL_LAB_AUTOCONNECT"] == "1", client == nil {
            connect()
        }
    }
}

/// Status line mirroring the lab spike: state, session, gen, grid, attaches.
private struct TerminalLabStatusBar: View {
    @ObservedObject var client: TerminalLabClient

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            Text(client.state.rawValue).foregroundStyle(stateColor)
            Text(client.sessionId)
            Text("gen \(client.gen)")
            Text("\(client.cols)x\(client.rows)")
            Text("attach #\(client.attachCount)")
            Spacer()
            if let err = client.lastError {
                Text(err).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(white: 0.85))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.08))
    }

    private var stateColor: Color {
        switch client.state {
        case .streaming: return .green
        case .exited: return .red
        case .idle: return .orange
        default: return .yellow
        }
    }
}

/// Mounts the production surface and bridges it to the lab client:
/// daemon bytes -> processOutput (SNAPSHOT prefixed with RIS so every attach
/// converges from a clean grid), typed bytes -> INPUT frames, natural-grid
/// changes -> RESIZE, server RESIZED -> applyViewSize.
private struct TerminalLabSurface: UIViewRepresentable {
    let client: TerminalLabClient

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.text = "Terminal Lab: Ghostty runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator, fontSize: 12)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?
        private let client: TerminalLabClient

        init(client: TerminalLabClient) {
            self.client = client
        }

        func start() {
            client.onSnapshot = { [weak self] bytes in
                // RIS before every snapshot: first attach and every re-attach
                // converge from a clean grid regardless of leftover modes or
                // alt-screen state from the previous attach epoch.
                var reset = Data([0x1B, UInt8(ascii: "c")])
                reset.append(bytes)
                self?.surfaceView?.processOutput(reset)
            }
            client.onOutput = { [weak self] bytes in
                self?.surfaceView?.processOutput(bytes)
            }
            client.onResized = { [weak self] cols, rows in
                self?.surfaceView?.applyViewSize(cols: Int(cols), rows: Int(rows))
            }
            client.start()
        }

        func stop() {
            client.stop()
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            client.sendInput(data)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            guard size.columns > 0, size.rows > 0 else { return }
            client.requestResize(cols: UInt16(clamping: size.columns),
                                 rows: UInt16(clamping: size.rows))
        }
    }
}
#endif
