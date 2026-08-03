import CCmuxTerminal
import Combine
import Foundation

struct TerminalGeometry: Equatable {
    let cols: UInt16
    let rows: UInt16
}

func terminalGeometry(
    width: CGFloat,
    height: CGFloat,
    horizontalInset: CGFloat = 0,
    verticalInset: CGFloat = 0
) -> TerminalGeometry {
    let usableWidth = max(0, width - horizontalInset)
    let usableHeight = max(0, height - verticalInset)
    return TerminalGeometry(
        cols: UInt16(max(1, min(10_000, Int(usableWidth / 8.4)))),
        rows: UInt16(max(1, min(10_000, Int(usableHeight / 17.0))))
    )
}

struct GeometryDeliveryState {
    private var desired: TerminalGeometry?
    private var delivered: TerminalGeometry?

    mutating func update(_ geometry: TerminalGeometry) {
        desired = geometry
    }

    func pending(isConnected: Bool) -> TerminalGeometry? {
        guard isConnected, desired != delivered else { return nil }
        return desired
    }

    mutating func complete(_ geometry: TerminalGeometry, accepted: Bool) {
        guard accepted, desired == geometry else { return }
        delivered = geometry
    }

    mutating func resetConnection() {
        delivered = nil
    }
}

private struct TerminalDiagnosticsEnvelope: Decodable {
    let status: String
}

private func terminalDidExit(_ diagnostics: String) -> Bool {
    guard let data = diagnostics.data(using: .utf8) else { return false }
    return (try? JSONDecoder().decode(TerminalDiagnosticsEnvelope.self, from: data).status)
        == "exited"
}

private struct ConnectedHandle: @unchecked Sendable {
    let raw: OpaquePointer?
    let error: String
}

final class TerminalClientHandle: @unchecked Sendable {
    private var raw: OpaquePointer?
    private var isAttached = true
    private let lock = NSLock()
    private let attachClient:
        (
            OpaquePointer,
            UnsafePointer<CChar>?,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Bool
    private let destroyClient: (OpaquePointer) -> Void
    private let detachClient: (OpaquePointer) -> Void
    private let sendClient:
        (
            OpaquePointer,
            UnsafePointer<UInt8>?,
            Int
        ) -> Bool
    private let pasteClient:
        (
            OpaquePointer,
            UnsafePointer<UInt8>?,
            Int
        ) -> Bool
    private let keyClient:
        (
            OpaquePointer,
            UnsafePointer<CChar>?,
            Bool
        ) -> Bool
    private let resizeClient: (OpaquePointer, UInt16, UInt16) -> Bool
    private let copyFrameClient:
        (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    private let copyDiagnosticsClient:
        (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int

    init(
        raw: OpaquePointer,
        attachClient:
            @escaping (
                OpaquePointer,
                UnsafePointer<CChar>?,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_attach($0, $1, $2, $3)
            },
        destroyClient: @escaping (OpaquePointer) -> Void = {
            cmux_terminal_client_disconnect($0)
        },
        detachClient: @escaping (OpaquePointer) -> Void = {
            cmux_terminal_client_detach($0)
        },
        sendClient:
            @escaping (
                OpaquePointer,
                UnsafePointer<UInt8>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_send($0, $1, $2)
            },
        pasteClient:
            @escaping (
                OpaquePointer,
                UnsafePointer<UInt8>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_paste($0, $1, $2)
            },
        keyClient:
            @escaping (
                OpaquePointer,
                UnsafePointer<CChar>?,
                Bool
            ) -> Bool = {
                cmux_terminal_client_send_key($0, $1, $2)
            },
        resizeClient: @escaping (OpaquePointer, UInt16, UInt16) -> Bool = {
            cmux_terminal_client_resize($0, $1, $2)
        },
        copyFrameClient:
            @escaping (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_frame($0, $1, $2)
            },
        copyDiagnosticsClient:
            @escaping (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_diagnostics($0, $1, $2)
            }
    ) {
        self.raw = raw
        self.attachClient = attachClient
        self.destroyClient = destroyClient
        self.detachClient = detachClient
        self.sendClient = sendClient
        self.pasteClient = pasteClient
        self.keyClient = keyClient
        self.resizeClient = resizeClient
        self.copyFrameClient = copyFrameClient
        self.copyDiagnosticsClient = copyDiagnosticsClient
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        guard let raw, isAttached else { return }
        isAttached = false
        detachClient(raw)
    }

    func reconnect(terminalID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw else {
            return L10n.text("error.client.closed", "The terminal client is closed.")
        }
        guard !isAttached else { return nil }
        var error = [CChar](repeating: 0, count: 1_024)
        let attached = terminalID.withCString { terminalPointer in
            attachClient(raw, terminalPointer, &error, error.count)
        }
        guard attached else {
            return String(
                decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        isAttached = true
        return nil
    }

    func submit(_ input: TerminalInput) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let raw, isAttached else { return false }
        switch input {
        case .bytes(let bytes):
            return bytes.withUnsafeBytes { bytes in
                sendClient(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        case .paste(let text):
            guard let bytes = text.data(using: .utf8) else { return false }
            return bytes.withUnsafeBytes { bytes in
                pasteClient(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        case .key(let chord, let isRepeat):
            return chord.withCString { keyClient(raw, $0, isRepeat) }
        }
    }

    func resize(to geometry: TerminalGeometry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let raw, isAttached else { return false }
        return resizeClient(raw, geometry.cols, geometry.rows)
    }

    func copyFrame() -> String? {
        copyString(using: copyFrameClient)
    }

    func copyDiagnostics() -> String? {
        copyString(using: copyDiagnosticsClient)
    }

    private func copyString(
        using copy: (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw, isAttached else { return nil }
        return copyGrowingCString { copy(raw, $0, $1) }
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard let raw else { return }
        self.raw = nil
        isAttached = false
        destroyClient(raw)
    }
}

struct DemoLaunchConfiguration: Equatable {
    let invitation: String
    let terminalID: String
    let autoConnect: Bool

    static func processEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoLaunchConfiguration {
        let invitation =
            environment["CMUX_TERMINAL_INVITATION_FILE"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
        return DemoLaunchConfiguration(
            invitation: invitation,
            terminalID: environment["CMUX_TERMINAL_ID"] ?? "",
            autoConnect: environment["CMUX_TERMINAL_AUTOCONNECT"] == "1"
        )
    }
}

func isTerminalPublicID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 37, bytes.starts(with: Array("term_".utf8)) else { return false }
    return bytes.dropFirst(5).allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
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
    @Published var terminalID: String
    @Published private(set) var frame = ""
    @Published private(set) var diagnostics = ""
    @Published private(set) var errorMessage = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false

    private var client: TerminalClientHandle?
    private var pollingTask: Task<Void, Never>?
    private var geometryDelivery = GeometryDeliveryState()
    private let shouldAutoConnect: Bool
    private var didAttemptAutoConnect = false
    private var isShuttingDown = false
    private var connectionOperation: UInt64 = 0

    init(
        configuration: DemoLaunchConfiguration = .processEnvironment(),
        retainedClient: TerminalClientHandle? = nil,
        initiallyConnected: Bool = false
    ) {
        invitation = configuration.invitation
        terminalID = configuration.terminalID
        shouldAutoConnect = configuration.autoConnect
        client = retainedClient
        isConnected = retainedClient != nil && initiallyConnected
    }

    func connectIfConfigured() {
        guard shouldAutoConnect, !didAttemptAutoConnect else { return }
        didAttemptAutoConnect = true
        connect()
    }

    func connect() {
        guard !isConnecting, !isShuttingDown else { return }
        let terminalID = terminalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTerminalPublicID(terminalID) else {
            errorMessage = L10n.text(
                "error.terminal",
                "Enter a terminal ID such as term_0123456789abcdef0123456789abcdef."
            )
            return
        }
        if let client {
            errorMessage = ""
            isConnecting = true
            connectionOperation &+= 1
            let operation = connectionOperation
            Task {
                let reconnectError = await Task.detached(priority: .userInitiated) {
                    client.reconnect(terminalID: terminalID)
                }.value
                guard operation == connectionOperation, !isShuttingDown else { return }
                isConnecting = false
                if let reconnectError {
                    errorMessage = reconnectError
                    return
                }
                isConnected = true
                geometryDelivery.resetConnection()
                sendPendingGeometry()
                beginPolling()
            }
            return
        }
        let invitation = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invitation.isEmpty else {
            errorMessage = L10n.text("error.invitation", "Paste an enrollment invitation.")
            return
        }
        errorMessage = ""
        isConnecting = true
        connectionOperation &+= 1
        let operation = connectionOperation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var error = [CChar](repeating: 0, count: 1_024)
                let handle = invitation.withCString { invitationPointer in
                    terminalID.withCString { terminalPointer in
                        cmux_terminal_client_connect(
                            invitationPointer,
                            terminalPointer,
                            &error,
                            error.count
                        )
                    }
                }
                return ConnectedHandle(
                    raw: handle,
                    error: String(
                        decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                )
            }.value
            guard operation == connectionOperation, !isShuttingDown else {
                if let handle = result.raw {
                    TerminalClientHandle(raw: handle).shutdown()
                }
                return
            }
            isConnecting = false
            guard let handle = result.raw else {
                errorMessage = result.error
                if let bytes = "TerminalBytes connection failed: \(result.error)\n"
                    .data(using: .utf8)
                {
                    try? FileHandle.standardError.write(contentsOf: bytes)
                }
                return
            }
            let client = TerminalClientHandle(raw: handle)
            guard !isShuttingDown else {
                client.shutdown()
                return
            }
            self.client = client
            isConnected = true
            geometryDelivery.resetConnection()
            sendPendingGeometry()
            beginPolling()
        }
    }

    func disconnect() {
        guard !isShuttingDown else { return }
        pollingTask?.cancel()
        pollingTask = nil
        isConnected = false
        diagnostics = ""
        geometryDelivery.resetConnection()
        connectionOperation &+= 1
        guard let client else {
            isConnecting = false
            return
        }
        isConnecting = true
        let operation = connectionOperation
        Task {
            await Task.detached(priority: .userInitiated) {
                client.disconnect()
            }.value
            guard operation == connectionOperation, !isShuttingDown else { return }
            isConnecting = false
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        connectionOperation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        isConnected = false
        isConnecting = false
        let ownedClient = client
        client = nil
        if let ownedClient {
            Task.detached(priority: .userInitiated) {
                ownedClient.shutdown()
            }
        }
    }

    @discardableResult
    func submit(_ input: TerminalInput) -> Bool {
        guard isConnected, let client else { return false }
        let accepted = client.submit(input)
        let failure = L10n.text(
            "error.input.rejected",
            "Terminal input was not queued. Reconnect and try again."
        )
        if !accepted {
            errorMessage = failure
        } else if errorMessage == failure {
            errorMessage = ""
        }
        return accepted
    }

    func resize(to geometry: TerminalGeometry) {
        geometryDelivery.update(geometry)
        sendPendingGeometry()
    }

    private func sendPendingGeometry() {
        guard let client,
            let geometry = geometryDelivery.pending(isConnected: isConnected)
        else { return }
        let accepted = client.resize(to: geometry)
        geometryDelivery.complete(geometry, accepted: accepted)
        let failure = L10n.text(
            "error.resize.rejected",
            "The terminal resize was not queued and will be retried."
        )
        if !accepted {
            errorMessage = failure
        } else if errorMessage == failure {
            errorMessage = ""
        }
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
        sendPendingGeometry()
        if let nextFrame = client.copyFrame() {
            frame = nextFrame
        }
        if let nextDiagnostics = client.copyDiagnostics() {
            diagnostics = nextDiagnostics
            if terminalDidExit(nextDiagnostics) {
                closeExitedAttachment(client)
            }
        }
    }

    private func closeExitedAttachment(_ client: TerminalClientHandle) {
        guard isConnected else { return }
        pollingTask?.cancel()
        pollingTask = nil
        isConnected = false
        geometryDelivery.resetConnection()
        errorMessage = ""
        isConnecting = true
        connectionOperation &+= 1
        let operation = connectionOperation
        Task {
            await Task.detached(priority: .userInitiated) {
                client.disconnect()
            }.value
            guard operation == connectionOperation, !isShuttingDown else { return }
            isConnecting = false
        }
    }
}
