public import Foundation

public actor CmuxTUITerminal {
    private static let maximumRenderPayloadBytes = 32 * 1_048_576

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

    public func drainRenderEvents() throws -> [CmuxTUIRenderEvent] {
        guard let raw else { return [] }
        var result: [CmuxTUIRenderEvent] = []
        while true {
            var descriptor = CmuxTUIRenderEventDescriptor()
            guard library.copyNextRenderEvent(
                terminal: raw,
                descriptor: &descriptor,
                buffer: nil,
                capacity: 0
            ) else {
                break
            }
            guard let kind = CmuxTUIRenderEvent.Kind(rawValue: descriptor.kind) else {
                if descriptor.payloadLength > 0 { break }
                continue
            }
            guard descriptor.payloadLength >= 0,
                  descriptor.payloadLength <= Self.maximumRenderPayloadBytes else {
                throw CmuxTUIClientError.invalidRenderEvent(
                    "render payload exceeds the native client limit"
                )
            }
            var payload = Data()
            if descriptor.payloadLength > 0 {
                payload = Data(count: descriptor.payloadLength)
                let copied = payload.withUnsafeMutableBytes { bytes in
                    library.copyNextRenderEvent(
                        terminal: raw,
                        descriptor: &descriptor,
                        buffer: bytes.bindMemory(to: UInt8.self).baseAddress,
                        capacity: bytes.count
                    )
                }
                guard copied else { break }
            }
            result.append(
                CmuxTUIRenderEvent(
                    kind: kind,
                    geometry: CmuxTUITerminalGeometry(
                        columns: descriptor.columns,
                        rows: descriptor.rows
                    ),
                    payload: payload
                )
            )
        }
        return result
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
