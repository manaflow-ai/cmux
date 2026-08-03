import CCmuxTerminal
import Foundation
import Observation

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

struct ConnectedHandle: Sendable {
    let rawAddress: UInt?
    let error: String
}

typealias TerminalConnector = @Sendable (String, String) -> ConnectedHandle

private let terminalConnectionTimeoutError = "terminal connection timed out"
private let defaultTerminalConnector: TerminalConnector = { invitation, terminalID in
    var error = [CChar](repeating: 0, count: 1_024)
    let handle = invitation.withCString { invitationPointer in
        terminalID.withCString { terminalPointer in
            cmux_terminal_client_connect_with_timeout(
                invitationPointer,
                terminalPointer,
                &error,
                error.count,
                15_000
            )
        }
    }
    return ConnectedHandle(
        rawAddress: handle.map { UInt(bitPattern: $0) },
        error: String(
            decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    )
}

struct TerminalClientSnapshot: Equatable, Sendable {
    let frame: String
    let diagnostics: String
}

struct TerminalClientUpdates: Sendable {
    let generation: UInt64
    let stream: AsyncStream<Void>
}

typealias TerminalUpdateCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

// AsyncStream.Continuation is thread-safe. Rust holds its callback mutex across
// invocation and synchronous removal, so this sink cannot be released in flight.
private final class TerminalUpdateSink: @unchecked Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

private let terminalUpdateCallback: TerminalUpdateCallback = { context in
    guard let context else { return }
    let sink = Unmanaged<TerminalUpdateSink>.fromOpaque(context).takeUnretainedValue()
    sink.continuation.yield()
}

actor TerminalClientHandle {
    private var raw: OpaquePointer?
    private var isAttached = true
    private var updateSink: TerminalUpdateSink?
    private var updateGeneration: UInt64 = 0
    private let attachClient:
        @Sendable (
            OpaquePointer,
            UnsafePointer<CChar>?,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Bool
    private let destroyClient: @Sendable (OpaquePointer) -> Void
    private let detachClient: @Sendable (OpaquePointer) -> Void
    private let setUpdateCallback:
        @Sendable (
            OpaquePointer,
            TerminalUpdateCallback?,
            UnsafeMutableRawPointer?
        ) -> Void
    private let sendClient:
        @Sendable (
            OpaquePointer,
            UnsafePointer<UInt8>?,
            Int
        ) -> Bool
    private let pasteClient:
        @Sendable (
            OpaquePointer,
            UnsafePointer<UInt8>?,
            Int
        ) -> Bool
    private let keyClient:
        @Sendable (
            OpaquePointer,
            UnsafePointer<CChar>?,
            Bool
        ) -> Bool
    private let resizeClient: @Sendable (OpaquePointer, UInt16, UInt16) -> Bool
    private let copyFrameClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    private let copyDiagnosticsClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int

    init(
        rawAddress: UInt,
        attachClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafePointer<CChar>?,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_attach($0, $1, $2, $3)
            },
        destroyClient: @escaping @Sendable (OpaquePointer) -> Void = {
            cmux_terminal_client_disconnect($0)
        },
        detachClient: @escaping @Sendable (OpaquePointer) -> Void = {
            cmux_terminal_client_detach($0)
        },
        setUpdateCallback:
            @escaping @Sendable (
                OpaquePointer,
                TerminalUpdateCallback?,
                UnsafeMutableRawPointer?
            ) -> Void = {
                cmux_terminal_client_set_update_callback($0, $1, $2)
            },
        sendClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafePointer<UInt8>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_send($0, $1, $2)
            },
        pasteClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafePointer<UInt8>?,
                Int
            ) -> Bool = {
                cmux_terminal_client_paste($0, $1, $2)
            },
        keyClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafePointer<CChar>?,
                Bool
            ) -> Bool = {
                cmux_terminal_client_send_key($0, $1, $2)
            },
        resizeClient: @escaping @Sendable (OpaquePointer, UInt16, UInt16) -> Bool = {
            cmux_terminal_client_resize($0, $1, $2)
        },
        copyFrameClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_frame($0, $1, $2)
            },
        copyDiagnosticsClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_diagnostics($0, $1, $2)
            }
    ) {
        self.raw = OpaquePointer(bitPattern: rawAddress)
        self.attachClient = attachClient
        self.destroyClient = destroyClient
        self.detachClient = detachClient
        self.setUpdateCallback = setUpdateCallback
        self.sendClient = sendClient
        self.pasteClient = pasteClient
        self.keyClient = keyClient
        self.resizeClient = resizeClient
        self.copyFrameClient = copyFrameClient
        self.copyDiagnosticsClient = copyDiagnosticsClient
    }

    func disconnect() {
        stopUpdates()
        guard let raw, isAttached else { return }
        isAttached = false
        detachClient(raw)
    }

    func reconnect(terminalID: String) -> String? {
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
        guard let raw, isAttached else { return false }
        return resizeClient(raw, geometry.cols, geometry.rows)
    }

    func updates() -> TerminalClientUpdates {
        stopUpdates()
        updateGeneration &+= 1
        let generation = updateGeneration
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        guard let raw, isAttached else {
            continuation.finish()
            return TerminalClientUpdates(generation: generation, stream: stream)
        }
        let sink = TerminalUpdateSink(continuation: continuation)
        updateSink = sink
        setUpdateCallback(
            raw,
            terminalUpdateCallback,
            Unmanaged.passUnretained(sink).toOpaque()
        )
        return TerminalClientUpdates(generation: generation, stream: stream)
    }

    func stopUpdates(generation: UInt64? = nil) {
        if let generation, generation != updateGeneration {
            return
        }
        guard let sink = updateSink else { return }
        if let raw {
            setUpdateCallback(raw, nil, nil)
        }
        sink.continuation.finish()
        updateSink = nil
        updateGeneration &+= 1
    }

    func snapshot() -> TerminalClientSnapshot? {
        guard raw != nil, isAttached,
            let frame = copyString(using: copyFrameClient),
            let diagnostics = copyString(using: copyDiagnosticsClient)
        else { return nil }
        return TerminalClientSnapshot(frame: frame, diagnostics: diagnostics)
    }

    private func copyString(
        using copy: @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    ) -> String? {
        guard let raw, isAttached else { return nil }
        return copyGrowingCString { copy(raw, $0, $1) }
    }

    func shutdown() {
        stopUpdates()
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

private struct QueuedTerminalInput: Sendable {
    let input: TerminalInput
    let client: TerminalClientHandle
    let connectionOperation: UInt64
}

private struct BoundedFIFO<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = [Element?](repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) -> Bool {
        guard count < storage.count else { return false }
        storage[(head + count) % storage.count] = element
        count += 1
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }

    mutating func removeAll() {
        storage = [Element?](repeating: nil, count: storage.count)
        head = 0
        count = 0
    }
}

@MainActor
@Observable
final class TerminalModel {
    var invitation: String
    var terminalID: String
    private(set) var frame = ""
    private(set) var diagnostics = ""
    private(set) var errorMessage = ""
    private(set) var isConnecting = false
    private(set) var isConnected = false

    @ObservationIgnored private var client: TerminalClientHandle?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputQueue = BoundedFIFO<QueuedTerminalInput>(capacity: 256)
    @ObservationIgnored private let inputWakeStream: AsyncStream<Void>
    @ObservationIgnored private let inputWakeContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeRetryTask: Task<Void, Never>?
    @ObservationIgnored private var resizeRetryAttempt = 0
    @ObservationIgnored private var resizeRetryExhausted = false
    @ObservationIgnored private var geometryDelivery = GeometryDeliveryState()
    @ObservationIgnored private let connectClient: TerminalConnector
    @ObservationIgnored private let shouldAutoConnect: Bool
    @ObservationIgnored private var didAttemptAutoConnect = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var connectionOperation: UInt64 = 0

    init(
        configuration: DemoLaunchConfiguration = .processEnvironment(),
        retainedClient: TerminalClientHandle? = nil,
        initiallyConnected: Bool = false,
        connectClient: TerminalConnector? = nil
    ) {
        let inputWake = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        inputWakeStream = inputWake.stream
        inputWakeContinuation = inputWake.continuation
        invitation = configuration.invitation
        terminalID = configuration.terminalID
        self.connectClient = connectClient ?? defaultTerminalConnector
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
                let reconnectError = await client.reconnect(terminalID: terminalID)
                guard operation == connectionOperation, !isShuttingDown else { return }
                isConnecting = false
                if let reconnectError {
                    errorMessage = reconnectError
                    return
                }
                isConnected = true
                geometryDelivery.resetConnection()
                resetResizeRetry()
                sendPendingGeometry()
                beginUpdates(from: client, operation: operation)
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
        let connectClient = connectClient
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                connectClient(invitation, terminalID)
            }.value
            guard operation == connectionOperation, !isShuttingDown else {
                if let address = result.rawAddress {
                    await TerminalClientHandle(rawAddress: address).shutdown()
                }
                return
            }
            isConnecting = false
            guard let address = result.rawAddress else {
                let displayError =
                    result.error == terminalConnectionTimeoutError
                    ? L10n.text(
                        "error.connect.timeout",
                        "Connection timed out. Check the invitation and try again."
                    )
                    : result.error
                errorMessage = displayError
                if let bytes = "TerminalBytes connection failed: \(displayError)\n"
                    .data(using: .utf8)
                {
                    try? FileHandle.standardError.write(contentsOf: bytes)
                }
                return
            }
            let client = TerminalClientHandle(rawAddress: address)
            guard !isShuttingDown else {
                await client.shutdown()
                return
            }
            self.client = client
            isConnected = true
            geometryDelivery.resetConnection()
            resetResizeRetry()
            sendPendingGeometry()
            beginUpdates(from: client, operation: operation)
        }
    }

    func disconnect() {
        guard !isShuttingDown else { return }
        updateTask?.cancel()
        updateTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        resetResizeRetry()
        inputQueue.removeAll()
        isConnected = false
        frame = ""
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
            await client.disconnect()
            guard operation == connectionOperation, !isShuttingDown else { return }
            isConnecting = false
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        connectionOperation &+= 1
        updateTask?.cancel()
        updateTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        resetResizeRetry()
        inputQueue.removeAll()
        inputWakeContinuation.finish()
        inputTask?.cancel()
        inputTask = nil
        isConnected = false
        isConnecting = false
        let ownedClient = client
        client = nil
        if let ownedClient {
            Task {
                await ownedClient.shutdown()
            }
        }
    }

    func submit(_ input: TerminalInput) {
        guard isConnected, let client else { return }
        let queued = QueuedTerminalInput(
            input: input,
            client: client,
            connectionOperation: connectionOperation
        )
        guard inputQueue.append(queued) else {
            errorMessage = L10n.text(
                "error.input.backpressure",
                "Terminal input is arriving faster than it can be sent. Wait and try again."
            )
            return
        }
        startInputConsumerIfNeeded()
        inputWakeContinuation.yield()
    }

    private func startInputConsumerIfNeeded() {
        guard inputTask == nil else { return }
        let stream = inputWakeStream
        inputTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self?.drainTerminalInputs()
            }
        }
    }

    private func drainTerminalInputs() async {
        let rejected = L10n.text(
            "error.input.rejected",
            "Terminal input was not queued. Reconnect and try again."
        )
        let backpressure = L10n.text(
            "error.input.backpressure",
            "Terminal input is arriving faster than it can be sent. Wait and try again."
        )
        while !Task.isCancelled, let queued = inputQueue.popFirst() {
            guard queued.connectionOperation == connectionOperation,
                queued.client === client,
                isConnected,
                !isShuttingDown
            else {
                continue
            }
            let accepted = await queued.client.submit(queued.input)
            guard queued.connectionOperation == connectionOperation,
                isConnected,
                !isShuttingDown
            else {
                continue
            }
            if accepted {
                if errorMessage == rejected || errorMessage == backpressure {
                    errorMessage = ""
                }
            } else {
                inputQueue.removeAll()
                errorMessage = rejected
                return
            }
        }
    }

    func resize(to geometry: TerminalGeometry) {
        let changed = geometryDelivery.pending(isConnected: true) != geometry
        geometryDelivery.update(geometry)
        if changed {
            resetResizeRetry()
        }
        sendPendingGeometry()
    }

    private func sendPendingGeometry() {
        guard resizeTask == nil,
            resizeRetryTask == nil,
            !resizeRetryExhausted,
            let client,
            let geometry = geometryDelivery.pending(isConnected: isConnected)
        else { return }
        let operation = connectionOperation
        let failure = L10n.text(
            "error.resize.rejected",
            "Terminal resize is pending. Resize the window or reconnect to retry."
        )
        resizeTask = Task {
            let accepted = await client.resize(to: geometry)
            guard operation == connectionOperation, !isShuttingDown else {
                resizeTask = nil
                return
            }
            geometryDelivery.complete(geometry, accepted: accepted)
            resizeTask = nil
            if accepted {
                resizeRetryAttempt = 0
                if errorMessage == failure {
                    errorMessage = ""
                }
                sendPendingGeometry()
                return
            }
            if geometryDelivery.pending(isConnected: isConnected) != geometry {
                resizeRetryAttempt = 0
                sendPendingGeometry()
                return
            }
            if !accepted {
                errorMessage = failure
            }
            scheduleResizeRetry(operation: operation)
        }
    }

    private func scheduleResizeRetry(operation: UInt64) {
        let delays: [Duration] = [.milliseconds(50), .milliseconds(100), .milliseconds(200)]
        guard resizeRetryTask == nil else { return }
        guard resizeRetryAttempt < delays.count else {
            resizeRetryExhausted = true
            return
        }
        let delay = delays[resizeRetryAttempt]
        resizeRetryAttempt += 1
        resizeRetryTask = Task {
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard operation == connectionOperation, isConnected, !isShuttingDown else {
                resizeRetryTask = nil
                return
            }
            resizeRetryTask = nil
            sendPendingGeometry()
        }
    }

    private func resetResizeRetry() {
        resizeRetryTask?.cancel()
        resizeRetryTask = nil
        resizeRetryAttempt = 0
        resizeRetryExhausted = false
    }

    private func beginUpdates(from client: TerminalClientHandle, operation: UInt64) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            let updates = await client.updates()
            let clock = ContinuousClock()
            var nextRender = clock.now
            for await _ in updates.stream {
                guard !Task.isCancelled else { break }
                if clock.now < nextRender {
                    do {
                        try await clock.sleep(until: nextRender, tolerance: .milliseconds(2))
                    } catch {
                        break
                    }
                }
                guard let snapshot = await client.snapshot() else { continue }
                guard let self,
                    operation == self.connectionOperation,
                    !self.isShuttingDown
                else { break }
                self.apply(snapshot, from: client)
                nextRender = clock.now.advanced(by: .milliseconds(33))
            }
            await client.stopUpdates(generation: updates.generation)
        }
    }

    private func apply(_ snapshot: TerminalClientSnapshot, from client: TerminalClientHandle) {
        if frame != snapshot.frame {
            frame = snapshot.frame
        }
        if diagnostics != snapshot.diagnostics {
            diagnostics = snapshot.diagnostics
        }
        if terminalDidExit(snapshot.diagnostics) {
            closeExitedAttachment(client)
        }
    }

    private func closeExitedAttachment(_ client: TerminalClientHandle) {
        guard isConnected else { return }
        updateTask?.cancel()
        updateTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        resetResizeRetry()
        inputQueue.removeAll()
        isConnected = false
        geometryDelivery.resetConnection()
        errorMessage = ""
        isConnecting = true
        connectionOperation &+= 1
        let operation = connectionOperation
        Task {
            await client.disconnect()
            guard operation == connectionOperation, !isShuttingDown else { return }
            isConnecting = false
        }
    }
}
