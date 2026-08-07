import CCmuxTerminal
import Foundation
import OSLog
import Observation

nonisolated private let terminalLogger = Logger(
    subsystem: "dev.cmux.TerminalBytesDemo",
    category: "TerminalModel"
)

struct TerminalGeometry: Equatable, Sendable {
    let cols: UInt16
    let rows: UInt16
}

struct TerminalResizeSubmission: Equatable, Sendable {
    let requestID: UInt64
    let geometry: TerminalGeometry
}

struct TerminalResizeAcknowledgement: Equatable, Sendable {
    let requestID: UInt64
    let geometry: TerminalGeometry
    let canonicalChanged: Bool
}

nonisolated protocol TerminalClock: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct ContinuousTerminalClock: TerminalClock {
    private let clock = ContinuousClock()

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

private let terminalResizeAcknowledgementTimeout = Duration.seconds(2)

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
    private var submitted: TerminalResizeSubmission?
    private var delivered: TerminalGeometry?

    @discardableResult
    mutating func update(_ geometry: TerminalGeometry) -> Bool {
        let changed = desired != geometry
        desired = geometry
        return changed
    }

    func pending(isConnected: Bool) -> TerminalGeometry? {
        guard isConnected, submitted == nil, desired != delivered else { return nil }
        return desired
    }

    mutating func submit(_ submission: TerminalResizeSubmission?) {
        guard let submission, desired == submission.geometry else { return }
        submitted = submission
    }

    @discardableResult
    mutating func acknowledge(_ acknowledgement: TerminalResizeAcknowledgement) -> Bool {
        guard let submitted,
            submitted.requestID == acknowledgement.requestID,
            submitted.geometry == acknowledgement.geometry
        else { return false }
        self.submitted = nil
        delivered = acknowledgement.geometry
        return true
    }

    mutating func expire(_ submission: TerminalResizeSubmission) -> Bool {
        guard submitted == self.submitted else { return false }
        self.submitted = nil
        return true
    }

    mutating func resetConnection() {
        submitted = nil
        delivered = nil
    }
}

struct ConnectedHandle: Sendable {
    let rawAddress: UInt?
    let error: String
}

private struct TerminalAttachResult: Sendable {
    let attached: Bool
    let error: String
}

private enum TerminalErrorKind: Equatable {
    case invalidTerminalID
    case missingInvitation
    case connection(String)
    case inputRejected
    case inputBackpressure
    case inputTooLarge
    case resizeRejected

    var isInputRelated: Bool {
        switch self {
        case .inputRejected, .inputBackpressure, .inputTooLarge:
            true
        case .invalidTerminalID, .missingInvitation, .connection, .resizeRejected:
            false
        }
    }

    var message: String {
        switch self {
        case .invalidTerminalID:
            L10n.text(
                "error.terminal",
                "Enter a terminal ID such as term_0123456789abcdef0123456789abcdef."
            )
        case .missingInvitation:
            L10n.text("error.invitation", "Paste an enrollment invitation.")
        case .connection(let message):
            message
        case .inputRejected:
            L10n.text(
                "error.input.rejected",
                "Terminal input was not queued. Reconnect and try again."
            )
        case .inputBackpressure:
            L10n.text(
                "error.input.backpressure",
                "Terminal input is arriving faster than it can be sent. Wait and try again."
            )
        case .inputTooLarge:
            L10n.text(
                "error.input.too_large",
                "Terminal input exceeds the 1 MiB limit."
            )
        case .resizeRejected:
            L10n.text(
                "error.resize.rejected",
                "Terminal resize is pending. Resize the window or reconnect to retry."
            )
        }
    }
}

typealias TerminalConnector = @Sendable (String, String) -> ConnectedHandle

private let terminalConnectionTimeoutError = "terminal connection timed out"
private let terminalConnectionTimeoutMilliseconds: UInt64 = 15_000

private func displayTerminalConnectionError(_ error: String) -> String {
    error == terminalConnectionTimeoutError
        ? L10n.text(
            "error.connect.timeout",
            "Connection timed out. Check the invitation and try again."
        )
        : error
}

private let defaultTerminalConnector: TerminalConnector = { invitation, terminalID in
    var error = [CChar](repeating: 0, count: 1_024)
    let handle = invitation.withCString { invitationPointer in
        terminalID.withCString { terminalPointer in
            cmux_terminal_client_connect_with_timeout(
                invitationPointer,
                terminalPointer,
                &error,
                error.count,
                terminalConnectionTimeoutMilliseconds
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
    let frame: String?
    let diagnostics: String
    let rowCount: Int
    let dirtyRows: [UInt16]
    let dirtyRowText: [UInt16: String]
    let didExit: Bool
    let resizeAcknowledgement: TerminalResizeAcknowledgement?
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
    private var isAttaching = false
    private var attachmentCancelled = false
    private var destroyAfterAttach = false
    private var isClosing = false
    private var updateSink: TerminalUpdateSink?
    private var updateGeneration: UInt64 = 0
    private let attachClient:
        @Sendable (
            OpaquePointer,
            UnsafePointer<CChar>?,
            UnsafeMutablePointer<CChar>?,
            Int,
            UInt64
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
    private let resizeClient:
        @Sendable (OpaquePointer, UInt16, UInt16, UnsafeMutablePointer<UInt64>?) -> Bool
    private let resizeAcknowledgementClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<UInt64>?,
            UnsafeMutablePointer<UInt16>?,
            UnsafeMutablePointer<UInt16>?,
            UnsafeMutablePointer<Bool>?
        ) -> Bool
    private let copyFrameClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    private let copyFrameDirtyRowsClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<UInt16>?,
            Int
        ) -> Int
    private let copyFrameRowClient:
        @Sendable (
            OpaquePointer,
            UInt16,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    private let frameRowCountClient: @Sendable (OpaquePointer) -> Int
    private let copyDiagnosticsClient:
        @Sendable (
            OpaquePointer,
            UnsafeMutablePointer<CChar>?,
            Int
        ) -> Int
    private let hasExitedClient: @Sendable (OpaquePointer) -> Bool
    private var frameSnapshotInitialized = false

    init(
        rawAddress: UInt,
        enableFrameDelta: Bool = false,
        attachClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafePointer<CChar>?,
                UnsafeMutablePointer<CChar>?,
                Int,
                UInt64
            ) -> Bool = {
                cmux_terminal_client_attach_with_timeout($0, $1, $2, $3, $4)
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
        resizeClient:
            @escaping @Sendable (
                OpaquePointer,
                UInt16,
                UInt16,
                UnsafeMutablePointer<UInt64>?
            ) -> Bool = {
                cmux_terminal_client_resize_with_request_id($0, $1, $2, $3)
            },
        resizeAcknowledgementClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<UInt64>?,
                UnsafeMutablePointer<UInt16>?,
                UnsafeMutablePointer<UInt16>?,
                UnsafeMutablePointer<Bool>?
            ) -> Bool = {
                cmux_terminal_client_last_resize_ack($0, $1, $2, $3, $4)
            },
        copyFrameClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_frame($0, $1, $2)
            },
        copyFrameDirtyRowsClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<UInt16>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_frame_dirty_rows($0, $1, $2)
            },
        copyFrameRowClient:
            @escaping @Sendable (
                OpaquePointer,
                UInt16,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_frame_row($0, $1, $2, $3)
            },
        frameRowCountClient: @escaping @Sendable (OpaquePointer) -> Int = {
            Int(cmux_terminal_client_frame_row_count($0))
        },
        copyDiagnosticsClient:
            @escaping @Sendable (
                OpaquePointer,
                UnsafeMutablePointer<CChar>?,
                Int
            ) -> Int = {
                cmux_terminal_client_copy_diagnostics($0, $1, $2)
            },
        hasExitedClient: @escaping @Sendable (OpaquePointer) -> Bool = {
            cmux_terminal_client_has_exited($0)
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
        self.resizeAcknowledgementClient = resizeAcknowledgementClient
        self.copyFrameClient = copyFrameClient
        if enableFrameDelta {
            self.copyFrameDirtyRowsClient = copyFrameDirtyRowsClient
            self.copyFrameRowClient = copyFrameRowClient
            self.frameRowCountClient = frameRowCountClient
        } else {
            self.copyFrameDirtyRowsClient = { _, _, _ in 0 }
            self.copyFrameRowClient = { _, _, _, _ in 0 }
            self.frameRowCountClient = { _ in 0 }
        }
        self.copyDiagnosticsClient = copyDiagnosticsClient
        self.hasExitedClient = hasExitedClient
    }

    func disconnect() {
        stopUpdates()
        if isAttaching {
            attachmentCancelled = true
            return
        }
        guard let raw, isAttached else { return }
        isAttached = false
        frameSnapshotInitialized = false
        detachClient(raw)
    }

    func reconnect(terminalID: String) async -> String? {
        guard let raw, !isClosing else {
            return L10n.text("error.client.closed", "The terminal client is closed.")
        }
        guard !isAttached else { return nil }
        guard !isAttaching else {
            return L10n.text(
                "error.connect.in_progress",
                "A terminal connection is already in progress."
            )
        }
        isAttaching = true
        attachmentCancelled = false
        let rawAddress = UInt(bitPattern: raw)
        let attachClient = attachClient
        let result = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                guard let raw = OpaquePointer(bitPattern: rawAddress) else {
                    continuation.resume(
                        returning: TerminalAttachResult(attached: false, error: "invalid client")
                    )
                    return
                }
                var error = [CChar](repeating: 0, count: 1_024)
                let attached = terminalID.withCString { terminalPointer in
                    attachClient(
                        raw,
                        terminalPointer,
                        &error,
                        error.count,
                        terminalConnectionTimeoutMilliseconds
                    )
                }
                continuation.resume(
                    returning: TerminalAttachResult(
                        attached: attached,
                        error: String(
                            decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                            as: UTF8.self
                        )
                    )
                )
            }
        }
        isAttaching = false
        if destroyAfterAttach {
            self.raw = nil
            destroyClient(raw)
            return L10n.text("error.client.closed", "The terminal client is closed.")
        }
        if attachmentCancelled {
            if result.attached {
                detachClient(raw)
            }
            return L10n.text("error.connect.cancelled", "The terminal connection was cancelled.")
        }
        guard result.attached else {
            return result.error
        }
        isAttached = true
        frameSnapshotInitialized = false
        return nil
    }

    func submit(_ input: TerminalInput) -> Bool {
        guard let prepared = PreparedTerminalInput(input, maximumBytes: Int.max) else {
            return false
        }
        return submitPrepared(prepared)
    }

    fileprivate func submitPrepared(_ input: PreparedTerminalInput) -> Bool {
        guard let raw, isAttached else { return false }
        switch input {
        case .bytes(let bytes):
            return bytes.withUnsafeBytes { bytes in
                sendClient(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        case .paste(let bytes):
            return bytes.withUnsafeBytes { bytes in
                pasteClient(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        case .key(let chord, let isRepeat):
            return chord.withCString { keyClient(raw, $0, isRepeat) }
        }
    }

    func resize(to geometry: TerminalGeometry) -> TerminalResizeSubmission? {
        guard let raw, isAttached else { return nil }
        var requestID: UInt64 = 0
        guard resizeClient(raw, geometry.cols, geometry.rows, &requestID), requestID != 0 else {
            return nil
        }
        return TerminalResizeSubmission(requestID: requestID, geometry: geometry)
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
        guard let raw, isAttached,
            let diagnostics = copyString(using: copyDiagnosticsClient)
        else { return nil }
        let dirtyRows = copyDirtyRows(raw)
        let rowCount = frameRowCountClient(raw)
        var dirtyRowText: [UInt16: String] = [:]
        for row in dirtyRows {
            guard let value = copyRowString(raw, row) else { return nil }
            dirtyRowText[row] = value
        }
        let frame: String?
        if frameSnapshotInitialized {
            frame = nil
        } else {
            guard let initialFrame = copyString(using: copyFrameClient) else { return nil }
            frame = initialFrame
            frameSnapshotInitialized = true
        }
        return TerminalClientSnapshot(
            frame: frame,
            diagnostics: diagnostics,
            rowCount: rowCount,
            dirtyRows: dirtyRows,
            dirtyRowText: dirtyRowText,
            didExit: hasExitedClient(raw),
            resizeAcknowledgement: resizeAcknowledgement(raw)
        )
    }

    private func copyDirtyRows(_ raw: OpaquePointer) -> [UInt16] {
        let required = copyFrameDirtyRowsClient(raw, nil, 0)
        guard required > 0 else { return [] }
        var rows = [UInt16](repeating: 0, count: required)
        let copied = rows.withUnsafeMutableBufferPointer {
            copyFrameDirtyRowsClient(raw, $0.baseAddress, $0.count)
        }
        guard copied == required else { return [] }
        return rows
    }

    private func copyRowString(_ raw: OpaquePointer, _ row: UInt16) -> String? {
        copyGrowingCString { buffer, capacity in
            copyFrameRowClient(raw, row, buffer, capacity)
        }
    }

    private func resizeAcknowledgement(
        _ raw: OpaquePointer
    ) -> TerminalResizeAcknowledgement? {
        var requestID: UInt64 = 0
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var canonicalChanged = false
        guard
            resizeAcknowledgementClient(
                raw,
                &requestID,
                &cols,
                &rows,
                &canonicalChanged
            )
        else { return nil }
        return TerminalResizeAcknowledgement(
            requestID: requestID,
            geometry: TerminalGeometry(cols: cols, rows: rows),
            canonicalChanged: canonicalChanged
        )
    }

    private func copyString(
        using copy:
            @Sendable (
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
        isClosing = true
        isAttached = false
        frameSnapshotInitialized = false
        if isAttaching {
            attachmentCancelled = true
            destroyAfterAttach = true
            return
        }
        self.raw = nil
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

let terminalCStringMaximumPayloadBytes = 16 * 1024 * 1024
let terminalCStringMaximumAttempts = 4

func copyGrowingCString(
    _ copy: (_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int
) -> String? {
    let maximumCapacity = terminalCStringMaximumPayloadBytes + 1
    let initialLength = copy(nil, 0)
    guard initialLength >= 0, initialLength < maximumCapacity else { return nil }
    var capacity = initialLength + 1
    for _ in 0..<terminalCStringMaximumAttempts {
        var buffer = [CChar](repeating: 0, count: capacity)
        let actual = copy(&buffer, buffer.count)
        guard actual >= 0 else { return nil }
        if actual < buffer.count {
            return String(
                decoding: buffer.prefix(actual).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
        }
        guard actual < maximumCapacity else { return nil }
        // The producer grew between sizing and copying. Its returned complete
        // length becomes the next capacity, so no truncated UTF-8 is decoded.
        capacity = actual + 1
    }
    return nil
}

let terminalInputMaximumPayloadBytes = 1_048_576
let terminalInputQueueByteCapacity = 4_194_304

private enum PreparedTerminalInput: Sendable {
    case bytes(Data)
    case paste(Data)
    case key(chord: String, repeat: Bool)

    init?(_ input: TerminalInput, maximumBytes: Int) {
        switch input {
        case .bytes(let bytes):
            guard bytes.count <= maximumBytes else { return nil }
            self = .bytes(bytes)
        case .paste(let text):
            guard boundedUTF8Count(text, maximumBytes: maximumBytes) != nil else { return nil }
            self = .paste(Data(text.utf8))
        case .key(let chord, let isRepeat):
            guard boundedUTF8Count(chord, maximumBytes: maximumBytes) != nil else { return nil }
            self = .key(chord: chord, repeat: isRepeat)
        }
    }

    var byteCount: Int {
        switch self {
        case .bytes(let bytes), .paste(let bytes):
            bytes.count
        case .key(let chord, _):
            chord.utf8.count
        }
    }
}

private func boundedUTF8Count(_ text: String, maximumBytes: Int) -> Int? {
    guard maximumBytes >= 0 else { return nil }
    if maximumBytes == Int.max {
        return text.utf8.count
    }
    let count = text.utf8.prefix(maximumBytes + 1).count
    return count <= maximumBytes ? count : nil
}

private struct QueuedTerminalInput: Sendable {
    let input: PreparedTerminalInput
    let client: TerminalClientHandle
    let connectionOperation: UInt64
}

private struct BoundedFIFO<Element> {
    private var storage: [(element: Element, byteCount: Int)?]
    private let byteCapacity: Int
    private var head = 0
    private(set) var count = 0
    private(set) var byteCount = 0

    init(capacity: Int, byteCapacity: Int) {
        precondition(capacity > 0 && byteCapacity > 0)
        storage = [(element: Element, byteCount: Int)?](repeating: nil, count: capacity)
        self.byteCapacity = byteCapacity
    }

    mutating func append(_ element: Element, byteCount: Int) -> Bool {
        guard count < storage.count,
            byteCount >= 0,
            byteCount <= byteCapacity,
            self.byteCount <= byteCapacity - byteCount
        else { return false }
        storage[(head + count) % storage.count] = (element, byteCount)
        count += 1
        self.byteCount += byteCount
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0, let entry = storage[head] else { return nil }
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        byteCount -= entry.byteCount
        return entry.element
    }

    mutating func removeAll() {
        storage = [(element: Element, byteCount: Int)?](repeating: nil, count: storage.count)
        head = 0
        count = 0
        byteCount = 0
    }
}

@MainActor
@Observable
final class TerminalModel {
    var invitation: String
    var terminalID: String
    private(set) var frame = ""
    private(set) var frameUpdate: String? = ""
    private(set) var dirtyRows: [UInt16] = []
    private(set) var dirtyRowText: [UInt16: String] = [:]
    private(set) var rowCount = 0
    private(set) var diagnostics = ""
    private var errorKind: TerminalErrorKind?
    var errorMessage: String { errorKind?.message ?? "" }
    private(set) var isConnecting = false
    private(set) var isConnected = false

    @ObservationIgnored private var client: TerminalClientHandle?
    @ObservationIgnored private var clientInvitation: String?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputQueue = BoundedFIFO<QueuedTerminalInput>(
        capacity: 256,
        byteCapacity: terminalInputQueueByteCapacity
    )
    @ObservationIgnored private let inputWakeStream: AsyncStream<Void>
    @ObservationIgnored private let inputWakeContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeAcknowledgementTask: Task<Void, Never>?
    @ObservationIgnored private var geometryDelivery = GeometryDeliveryState()
    @ObservationIgnored private var resizeAcknowledgementRetryAvailable = true
    @ObservationIgnored private var resizeRetryBlockedGeometry: TerminalGeometry?
    @ObservationIgnored private let resizeClock: any TerminalClock
    @ObservationIgnored private let resizeAcknowledgementTimeout: Duration
    @ObservationIgnored private let connectClient: TerminalConnector
    @ObservationIgnored private let shouldAutoConnect: Bool
    @ObservationIgnored private var didAttemptAutoConnect = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var connectionOperation: UInt64 = 0
    @ObservationIgnored private var rendererGeneration: UInt64 = 0

    init(
        configuration: DemoLaunchConfiguration = .processEnvironment(),
        retainedClient: TerminalClientHandle? = nil,
        initiallyConnected: Bool = false,
        connectClient: TerminalConnector? = nil,
        resizeClock: any TerminalClock = ContinuousTerminalClock(),
        resizeAcknowledgementTimeout: Duration = terminalResizeAcknowledgementTimeout
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
        self.resizeClock = resizeClock
        self.resizeAcknowledgementTimeout = resizeAcknowledgementTimeout
        shouldAutoConnect = configuration.autoConnect
        client = retainedClient
        let retainedInvitation = configuration.invitation.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        clientInvitation =
            retainedClient != nil && !retainedInvitation.isEmpty ? retainedInvitation : nil
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
            errorKind = .invalidTerminalID
            return
        }
        let invitation = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let client,
            clientInvitation.map({ $0 == invitation }) ?? invitation.isEmpty
        {
            errorKind = nil
            isConnecting = true
            connectionOperation &+= 1
            let operation = connectionOperation
            Task {
                let reconnectError = await client.reconnect(terminalID: terminalID)
                guard operation == connectionOperation, !isShuttingDown else { return }
                isConnecting = false
                if let reconnectError {
                    errorKind = .connection(displayTerminalConnectionError(reconnectError))
                    return
                }
                isConnected = true
                beginUpdates(from: client, operation: operation)
            }
            return
        }
        guard !invitation.isEmpty else {
            errorKind = .missingInvitation
            return
        }
        let replacedClient = client
        if replacedClient != nil {
            updateTask?.cancel()
            updateTask = nil
            resizeTask?.cancel()
            resizeTask = nil
            resizeAcknowledgementTask?.cancel()
            resizeAcknowledgementTask = nil
            inputQueue.removeAll()
            isConnected = false
            frame = ""
            frameUpdate = ""
            dirtyRows = []
            dirtyRowText = [:]
            rowCount = 0
            diagnostics = ""
            geometryDelivery.resetConnection()
            client = nil
            clientInvitation = nil
        }
        errorKind = nil
        isConnecting = true
        connectionOperation &+= 1
        let operation = connectionOperation
        let connectClient = connectClient
        Task {
            if let replacedClient {
                await replacedClient.shutdown()
            }
            guard operation == connectionOperation, !isShuttingDown else { return }
            let result = await Task.detached(priority: .userInitiated) {
                connectClient(invitation, terminalID)
            }.value
            guard operation == connectionOperation, !isShuttingDown else {
                if let address = result.rawAddress {
                    await TerminalClientHandle(rawAddress: address, enableFrameDelta: true).shutdown()
                }
                return
            }
            isConnecting = false
            guard let address = result.rawAddress else {
                let displayError = displayTerminalConnectionError(result.error)
                errorKind = .connection(displayError)
                terminalLogger.error(
                    "TerminalBytes connection failed: \(displayError, privacy: .private)"
                )
                return
            }
            let client = TerminalClientHandle(rawAddress: address, enableFrameDelta: true)
            guard !isShuttingDown else {
                await client.shutdown()
                return
            }
            self.client = client
            clientInvitation = invitation
            isConnected = true
            beginUpdates(from: client, operation: operation)
        }
    }

    func disconnect() {
        guard !isShuttingDown else { return }
        updateTask?.cancel()
        updateTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        resizeAcknowledgementTask?.cancel()
        resizeAcknowledgementTask = nil
        inputQueue.removeAll()
        isConnected = false
        frame = ""
        frameUpdate = ""
        dirtyRows = []
        dirtyRowText = [:]
        rowCount = 0
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
        resizeAcknowledgementTask?.cancel()
        resizeAcknowledgementTask = nil
        inputQueue.removeAll()
        inputWakeContinuation.finish()
        inputTask?.cancel()
        inputTask = nil
        isConnected = false
        isConnecting = false
        let ownedClient = client
        client = nil
        clientInvitation = nil
        if let ownedClient {
            Task {
                await ownedClient.shutdown()
            }
        }
    }

    func submit(_ input: TerminalInput) {
        guard isConnected, let client else { return }
        guard
            let prepared = PreparedTerminalInput(
                input,
                maximumBytes: terminalInputMaximumPayloadBytes
            )
        else {
            errorKind = .inputTooLarge
            return
        }
        let queued = QueuedTerminalInput(
            input: prepared,
            client: client,
            connectionOperation: connectionOperation
        )
        guard inputQueue.append(queued, byteCount: prepared.byteCount) else {
            errorKind = .inputBackpressure
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
        while !Task.isCancelled, let queued = inputQueue.popFirst() {
            guard queued.connectionOperation == connectionOperation,
                queued.client === client,
                isConnected,
                !isShuttingDown
            else {
                continue
            }
            let accepted = await queued.client.submitPrepared(queued.input)
            guard queued.connectionOperation == connectionOperation,
                isConnected,
                !isShuttingDown
            else {
                continue
            }
            if accepted {
                if errorKind?.isInputRelated == true {
                    errorKind = nil
                }
            } else {
                inputQueue.removeAll()
                errorKind = .inputRejected
                return
            }
        }
    }

    func resize(to geometry: TerminalGeometry) {
        if geometryDelivery.update(geometry) {
            resetResizeAcknowledgementRetryBudget()
        }
        sendPendingGeometry()
    }

    private func sendPendingGeometry() {
        guard resizeTask == nil,
            let client,
            let geometry = geometryDelivery.pending(isConnected: isConnected),
            resizeRetryBlockedGeometry != geometry
        else { return }
        let operation = connectionOperation
        let generation = rendererGeneration
        resizeTask = Task {
            let submission = await client.resize(to: geometry)
            guard operation == connectionOperation,
                generation == rendererGeneration,
                !isShuttingDown
            else {
                // Lifecycle teardown already cleared the obsolete task slot.
                // Do not let an old operation erase a replacement task.
                return
            }
            geometryDelivery.submit(submission)
            resizeTask = nil
            if let submission {
                startResizeAcknowledgementDeadline(
                    for: submission,
                    operation: operation,
                    rendererGeneration: generation
                )
                if let snapshot = await client.snapshot(),
                    operation == connectionOperation,
                    generation == rendererGeneration,
                    !isShuttingDown
                {
                    apply(snapshot, from: client)
                }
                return
            }
            errorKind = .resizeRejected
            resizeRetryBlockedGeometry = geometry
        }
    }

    private func startResizeAcknowledgementDeadline(
        for submission: TerminalResizeSubmission,
        operation: UInt64,
        rendererGeneration: UInt64
    ) {
        resizeAcknowledgementTask?.cancel()
        let clock = resizeClock
        let timeout = resizeAcknowledgementTimeout
        resizeAcknowledgementTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                operation == self.connectionOperation,
                rendererGeneration == self.rendererGeneration,
                !self.isShuttingDown,
                self.geometryDelivery.expire(submission)
            else { return }
            self.resizeAcknowledgementTask = nil
            self.errorKind = .resizeRejected
            if self.resizeAcknowledgementRetryAvailable {
                self.resizeAcknowledgementRetryAvailable = false
                self.sendPendingGeometry()
            } else {
                self.resizeRetryBlockedGeometry = submission.geometry
            }
        }
    }

    private func resetResizeAcknowledgementRetryBudget() {
        resizeAcknowledgementRetryAvailable = true
        resizeRetryBlockedGeometry = nil
    }

    private func beginUpdates(from client: TerminalClientHandle, operation: UInt64) {
        updateTask?.cancel()
        resizeAcknowledgementTask?.cancel()
        resizeAcknowledgementTask = nil
        rendererGeneration &+= 1
        resetResizeAcknowledgementRetryBudget()
        let generation = rendererGeneration
        geometryDelivery.resetConnection()
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
                nextRender = clock.now.advanced(by: .milliseconds(33))
                guard let snapshot = await client.snapshot() else { continue }
                guard let self,
                    operation == self.connectionOperation,
                    generation == self.rendererGeneration,
                    !self.isShuttingDown
                else { break }
                self.apply(snapshot, from: client)
            }
            await client.stopUpdates(generation: updates.generation)
        }
        sendPendingGeometry()
    }

    private func apply(_ snapshot: TerminalClientSnapshot, from client: TerminalClientHandle) {
        if let acknowledgement = snapshot.resizeAcknowledgement {
            if geometryDelivery.acknowledge(acknowledgement) {
                resizeAcknowledgementTask?.cancel()
                resizeAcknowledgementTask = nil
                resetResizeAcknowledgementRetryBudget()
                if errorKind == .resizeRejected {
                    errorKind = nil
                }
            }
        }
        frameUpdate = snapshot.frame
        dirtyRows = snapshot.dirtyRows
        dirtyRowText = snapshot.dirtyRowText
        rowCount = snapshot.rowCount
        if let snapshotFrame = snapshot.frame {
            frame = snapshotFrame
        }
        if diagnostics != snapshot.diagnostics {
            diagnostics = snapshot.diagnostics
        }
        if snapshot.didExit {
            closeExitedAttachment(client)
        } else {
            sendPendingGeometry()
        }
    }

    private func closeExitedAttachment(_ client: TerminalClientHandle) {
        guard isConnected else { return }
        updateTask?.cancel()
        updateTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        resizeAcknowledgementTask?.cancel()
        resizeAcknowledgementTask = nil
        inputQueue.removeAll()
        isConnected = false
        geometryDelivery.resetConnection()
        errorKind = nil
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
