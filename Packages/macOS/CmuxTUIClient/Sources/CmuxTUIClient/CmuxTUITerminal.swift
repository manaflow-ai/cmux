public import Foundation

private let cmuxTUIRenderMaximumEventCount = 256
private let cmuxTUIRenderMaximumBatchPayloadBytes = 8 * 1_048_576
private let cmuxTUIRenderMaximumEventPayloadBytes = 32 * 1_048_576

typealias CmuxTUIRenderEventCopy = (
    _ descriptor: inout CmuxTUIRenderEventDescriptor,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int
) -> Bool

func drainCmuxTUIRenderEventBatch(
    maximumEventCount: Int = cmuxTUIRenderMaximumEventCount,
    maximumBatchPayloadBytes: Int = cmuxTUIRenderMaximumBatchPayloadBytes,
    maximumEventPayloadBytes: Int = cmuxTUIRenderMaximumEventPayloadBytes,
    copyNext: CmuxTUIRenderEventCopy
) -> CmuxTUIRenderEventBatch {
    precondition(maximumEventCount > 0)
    precondition(maximumBatchPayloadBytes > 0)
    precondition(maximumEventPayloadBytes > 0)

    var events: [CmuxTUIRenderEvent] = []
    events.reserveCapacity(min(maximumEventCount, 32))
    var payloadBytes = 0

    func failed(_ message: String) -> CmuxTUIRenderEventBatch {
        CmuxTUIRenderEventBatch(
            events: events,
            hasMore: false,
            failure: .invalidRenderEvent(message)
        )
    }

    while events.count < maximumEventCount {
        var descriptor = CmuxTUIRenderEventDescriptor()
        guard copyNext(&descriptor, nil, 0) else {
            return CmuxTUIRenderEventBatch(events: events, hasMore: false)
        }
        guard descriptor.payloadLength >= 0,
              descriptor.payloadLength <= maximumEventPayloadBytes else {
            return failed(
                "render payload exceeds the native client limit"
            )
        }
        if !events.isEmpty,
           descriptor.payloadLength > maximumBatchPayloadBytes - payloadBytes {
            return CmuxTUIRenderEventBatch(events: events, hasMore: true)
        }

        var payload = Data()
        if descriptor.payloadLength > 0 {
            payload = Data(count: descriptor.payloadLength)
            let copied = payload.withUnsafeMutableBytes { bytes in
                copyNext(
                    &descriptor,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
            guard copied else {
                return failed(
                    "render payload changed before the native client could copy it"
                )
            }
        }
        guard let kind = CmuxTUIRenderEvent.Kind(rawValue: descriptor.kind) else {
            return failed(
                "unknown native render event kind: \(descriptor.kind)"
            )
        }
        events.append(
            CmuxTUIRenderEvent(
                kind: kind,
                geometry: CmuxTUITerminalGeometry(
                    columns: descriptor.columns,
                    rows: descriptor.rows
                ),
                payload: payload
            )
        )
        payloadBytes += payload.count
        if kind == .reset
            || events.count == maximumEventCount
            || payloadBytes >= maximumBatchPayloadBytes {
            return CmuxTUIRenderEventBatch(events: events, hasMore: true)
        }
    }

    return CmuxTUIRenderEventBatch(events: events, hasMore: true)
}

public actor CmuxTUITerminal {
    private let library: CmuxTUIClientLibrary
    private var raw: OpaquePointer?
    private var updateSink: CmuxTUIUpdateSink?
    private var updateGeneration: UInt64 = 0

    init(library: CmuxTUIClientLibrary, rawAddress: UInt) {
        self.library = library
        raw = OpaquePointer(bitPattern: rawAddress)
    }

    public func send(_ data: Data) -> Bool {
        guard let raw else { return false }
        return library.send(data, terminal: raw)
    }

    public func sendKey(_ chord: String, repeat isRepeat: Bool = false) -> Bool {
        guard let raw else { return false }
        return library.sendKey(chord, repeat: isRepeat, terminal: raw)
    }

    public func paste(_ data: Data) -> Bool {
        guard let raw else { return false }
        return library.paste(data, terminal: raw)
    }

    public func resize(_ geometry: CmuxTUITerminalGeometry) -> Bool {
        guard let raw else { return false }
        return library.resize(geometry, terminal: raw)
    }

    public func updates() -> CmuxTUIUpdateSubscription {
        stopUpdates()
        updateGeneration &+= 1
        let generation = updateGeneration
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard let raw else {
            pair.continuation.finish()
            return CmuxTUIUpdateSubscription(generation: generation, stream: pair.stream)
        }
        let sink = CmuxTUIUpdateSink(pair.continuation)
        updateSink = sink
        library.setTerminalUpdateCallback(
            raw,
            callback: cmuxTUIUpdateCallback,
            context: Unmanaged.passUnretained(sink).toOpaque()
        )
        return CmuxTUIUpdateSubscription(generation: generation, stream: pair.stream)
    }

    public func drainRenderEventBatch() -> CmuxTUIRenderEventBatch {
        guard let raw else {
            return CmuxTUIRenderEventBatch(events: [], hasMore: false)
        }
        // Carry the opaque handle across Data's closure as a plain value.
        // Swift 6.2 otherwise treats the actor-isolated pointer capture as a
        // potential concurrent access even though this method never suspends.
        let rawAddress = UInt(bitPattern: raw)
        return drainCmuxTUIRenderEventBatch { descriptor, buffer, capacity in
            library.copyNextRenderEvent(
                terminal: OpaquePointer(bitPattern: rawAddress),
                descriptor: &descriptor,
                buffer: buffer,
                capacity: capacity
            )
        }
    }

    public func snapshot() -> CmuxTUITerminalSnapshot {
        CmuxTUITerminalSnapshot(
            diagnostics: library.terminalDiagnostics(raw),
            didExit: library.terminalHasExited(raw)
        )
    }

    public func stopUpdates(generation: UInt64? = nil) {
        if let generation, generation != updateGeneration { return }
        guard let sink = updateSink else { return }
        if let raw {
            library.setTerminalUpdateCallback(raw, callback: nil, context: nil)
        }
        sink.continuation.finish()
        updateSink = nil
        updateGeneration &+= 1
    }

    public func shutdown() {
        stopUpdates()
        guard let raw else { return }
        self.raw = nil
        library.disconnectTerminal(raw)
    }
}
