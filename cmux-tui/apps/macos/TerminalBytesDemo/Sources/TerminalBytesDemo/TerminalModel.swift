import CCmuxTerminal
import Combine
import Foundation

struct TerminalGeometry: Equatable {
    let cols: UInt16
    let rows: UInt16
}

func terminalGeometry(width: CGFloat, height: CGFloat) -> TerminalGeometry {
    TerminalGeometry(
        cols: UInt16(max(1, min(10_000, Int(width / 8.4)))),
        rows: UInt16(max(1, min(10_000, Int(height / 17.0))))
    )
}

private struct ConnectedHandle: @unchecked Sendable {
    let raw: OpaquePointer?
    let error: String
}

struct DemoLaunchConfiguration: Equatable {
    let invitation: String
    let surface: String
    let autoConnect: Bool

    static func processEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoLaunchConfiguration {
        let invitation = environment["CMUX_TERMINAL_INVITATION_FILE"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
        return DemoLaunchConfiguration(
            invitation: invitation,
            surface: environment["CMUX_TERMINAL_SURFACE"] ?? "",
            autoConnect: environment["CMUX_TERMINAL_AUTOCONNECT"] == "1"
        )
    }
}

func copyGrowingCString(
    _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
) -> String {
    var capacity = copy(nil, 0) + 1
    while true {
        var buffer = [CChar](repeating: 0, count: capacity)
        let actual = copy(&buffer, buffer.count)
        if actual < buffer.count {
            return String(
                decoding: buffer.prefix(actual).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        // The producer grew between sizing and copying. Its returned complete
        // length becomes the next capacity, so no truncated UTF-8 is decoded.
        capacity = actual + 1
    }
}

@MainActor
final class TerminalModel: ObservableObject {
    @Published var invitation: String
    @Published var surface: String
    @Published private(set) var frame = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false

    private var client: OpaquePointer?
    private var pollingTask: Task<Void, Never>?
    private var lastGeometry: TerminalGeometry?
    private let shouldAutoConnect: Bool
    private var didAttemptAutoConnect = false

    init(configuration: DemoLaunchConfiguration = .processEnvironment()) {
        invitation = configuration.invitation
        surface = configuration.surface
        shouldAutoConnect = configuration.autoConnect
    }

    func connectIfConfigured() {
        guard shouldAutoConnect, !didAttemptAutoConnect else { return }
        didAttemptAutoConnect = true
        connect()
    }

    func connect() {
        guard client == nil, !isConnecting else { return }
        guard let surfaceID = UInt64(surface) else {
            errorMessage = L10n.text("error.surface", "Enter a numeric surface ID.")
            return
        }
        let invitation = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invitation.isEmpty else {
            errorMessage = L10n.text("error.invitation", "Paste an enrollment invitation.")
            return
        }
        errorMessage = ""
        isConnecting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var error = [CChar](repeating: 0, count: 1_024)
                let handle = invitation.withCString { invitationPointer in
                    cmux_terminal_client_connect(
                        invitationPointer,
                        surfaceID,
                        &error,
                        error.count
                    )
                }
                return ConnectedHandle(
                    raw: handle,
                    error: String(
                        decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                )
            }.value
            isConnecting = false
            guard let handle = result.raw else {
                errorMessage = result.error
                if let bytes = "TerminalBytes connection failed: \(result.error)\n"
                    .data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: bytes)
                }
                return
            }
            client = handle
            isConnected = true
            beginPolling()
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        if let client {
            cmux_terminal_client_disconnect(client)
        }
        client = nil
        isConnected = false
        diagnostics = ""
        lastGeometry = nil
    }

    func send(_ bytes: Data) {
        guard let client else { return }
        bytes.withUnsafeBytes { raw in
            _ = cmux_terminal_client_send(
                client,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            )
        }
    }

    func paste(_ text: String) {
        guard let client, let bytes = text.data(using: .utf8) else { return }
        bytes.withUnsafeBytes { raw in
            _ = cmux_terminal_client_paste(
                client,
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count
            )
        }
    }

    func resize(to geometry: TerminalGeometry) {
        guard geometry != lastGeometry, let client else { return }
        lastGeometry = geometry
        _ = cmux_terminal_client_resize(client, geometry.cols, geometry.rows)
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func poll() {
        guard let client else { return }
        frame = copyString { buffer, capacity in
            cmux_terminal_client_copy_frame(client, buffer, capacity)
        }
        diagnostics = copyString { buffer, capacity in
            cmux_terminal_client_copy_diagnostics(client, buffer, capacity)
        }
    }

    private func copyString(
        _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
    ) -> String {
        copyGrowingCString(copy)
    }
}
