import Foundation
import Testing
@testable import CMUXMobileCore

/// Micro-benchmark for the reserved RAW TERMINAL CHANNEL decision
/// (RelayProtocol.channelTerminal).
///
/// Measures the per-frame CPU cost that a dedicated binary channel would
/// remove from the render-grid path, on representative payloads:
///
/// Today (JSON event envelope over the RPC channel):
///   Mac:   splice `{"kind":"event","topic":...,"payload":<frame JSON>}`
///          around the already-encoded frame, then length-frame it
///          (MobileHostService.emitRenderGridEvent).
///   Phone: length-decode, optional zlib inflate, JSONSerialization parse of
///          the WHOLE envelope (including the frame) into Foundation objects,
///          topic extraction, re-serialize the payload dict back to Data,
///          then JSONDecoder into MobileTerminalRenderGridFrame
///          (MobileCoreRPCSession.dispatch -> handleTerminalRenderGridEvent).
///
/// Raw channel (hypothetical):
///   Mac:   build a small binary header [version][flags][surfaceID][anchor]
///          [seq], append the frame JSON payload.
///   Phone: parse the header, optional inflate, JSONDecoder the payload
///          slice directly into MobileTerminalRenderGridFrame.
///
/// The channel's win is therefore: envelope splice (Mac, ~0) plus
/// JSONSerialization full parse + payload re-serialization (phone). The typed
/// JSONDecoder decode and compression are common to both paths.
///
/// Run:
///   cd Packages/Shared/CMUXMobileCore
///   swift test -c release --filter RenderGridEnvelopeOverheadBenchmark
@Suite struct RenderGridEnvelopeOverheadBenchmark {
    // MARK: - Payload construction

    /// Builds a frame whose JSONEncoder encoding is at least `targetBytes`,
    /// shaped like real traffic: spans with mixed styles across a 120-column
    /// grid (delta) or a full repaint with scrollback (full frame).
    private static func makeFrame(
        targetBytes: Int,
        full: Bool
    ) throws -> MobileTerminalRenderGridFrame {
        let columns = 120
        let rows = 50
        var styles: [MobileTerminalRenderGridFrame.Style] = [.default]
        for id in 1...24 {
            styles.append(
                MobileTerminalRenderGridFrame.Style(
                    id: id,
                    foreground: String(format: "%06x", id * 65793 & 0xFFFFFF),
                    background: id % 3 == 0 ? "1e1e2e" : nil,
                    bold: id % 4 == 0,
                    italic: id % 5 == 0,
                    underline: id % 7 == 0
                )
            )
        }
        func spanText(_ row: Int, _ i: Int) -> String {
            // Realistic terminal content: paths, hex, prose.
            "worktrees/feat-raw-\(row)-\(i) 0x\(String(row * 2654435761 & 0xFFFFFF, radix: 16)) build ok in 12.\(i)s "
        }
        var rowSpans: [MobileTerminalRenderGridFrame.RowSpan] = []
        var scrollbackSpans: [MobileTerminalRenderGridFrame.RowSpan] = []
        var encodedCount = 0
        var row = 0
        var i = 0
        while true {
            let text = String(spanText(row, i).prefix(58))
            let column = (i % 2) * 60
            rowSpans.append(
                MobileTerminalRenderGridFrame.RowSpan(
                    row: row,
                    column: column,
                    styleID: i % 25,
                    text: text
                )
            )
            i += 1
            if i % 2 == 0 { row = (row + 1) % rows }
            if i % 8 == 0 {
                let frame = try MobileTerminalRenderGridFrame(
                    surfaceID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                    stateSeq: 482_113,
                    renderEpoch: "b1946ac9",
                    renderRevision: 90_210,
                    columns: columns,
                    rows: rows,
                    cursor: .init(row: 12, column: 40),
                    full: full,
                    clearedRows: full ? [] : [3, 4, 5, 9],
                    styles: styles,
                    rowSpans: rowSpans,
                    modes: [.init(code: 2004, ansi: false, on: true)],
                    terminalForeground: "cdd6f4",
                    terminalBackground: "1e1e2e",
                    scrollbackRows: full ? 200 : 0,
                    scrollbackSpans: scrollbackSpans,
                    anchor: .screen,
                    historyRows: 14_002,
                    rowSpaceRevision: 3,
                    deltaBaseHistoryRows: full ? nil : 13_998
                )
                encodedCount = try JSONEncoder().encode(frame).count
                if encodedCount >= targetBytes { return frame }
                if full, scrollbackSpans.count < 190 {
                    scrollbackSpans.append(
                        MobileTerminalRenderGridFrame.RowSpan(
                            row: scrollbackSpans.count,
                            column: 0,
                            styleID: scrollbackSpans.count % 25,
                            text: String(spanText(scrollbackSpans.count, 7).prefix(58))
                        )
                    )
                }
            }
        }
    }

    // MARK: - Timing helpers

    @inline(never)
    private static func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }

    /// Returns (mean, p50) microseconds per call over `iterations` runs.
    private static func measure(
        iterations: Int = 300,
        warmup: Int = 30,
        _ body: () throws -> Void
    ) rethrows -> (mean: Double, p50: Double) {
        for _ in 0..<warmup { try body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1000.0)
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        return (mean, samples[samples.count / 2])
    }

    // MARK: - Path replicas

    /// Mac emit, JSON path: envelope splice + length framing
    /// (mirrors MobileHostService.emitRenderGridEvent).
    private static func macEmitJSON(payloadJSON: Data) throws -> Data {
        var envelope = Data(#"{"kind":"event","topic":"terminal.render_grid","payload":"#.utf8)
        envelope.append(payloadJSON)
        envelope.append(UInt8(ascii: "}"))
        return try MobileSyncFrameCodec.encodeFrame(envelope)
    }

    /// Mac emit, raw-channel path: binary header + payload. Header shape from
    /// the reserved-channel sketch: [version][flags][surfaceID][anchor][seq].
    private static func macEmitRaw(
        payloadJSON: Data,
        surfaceID: String,
        seq: UInt64
    ) -> Data {
        var out = Data(capacity: payloadJSON.count + 64)
        out.append(1) // version
        out.append(0) // flags
        let sid = Data(surfaceID.utf8)
        out.append(UInt8(sid.count))
        out.append(sid)
        out.append(1) // anchor = screen
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { out.append(contentsOf: $0) }
        out.append(payloadJSON)
        return out
    }

    /// Phone receive, JSON path: mirrors MobileCoreRPCSession.dispatch(frame:)
    /// plus handleTerminalRenderGridEvent's typed decode.
    private static func phoneReceiveJSON(wire: Data) throws {
        var buffer = wire
        let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for frame in frames {
            guard let inflated = MobileEventFrameCompression.inflatedFrame(
                frame,
                maximumInflatedByteCount: MobileSyncFrameCodec.defaultMaximumFrameByteCount
            ) else { fatalError("inflate failed") }
            guard let envelope = try JSONSerialization.jsonObject(with: inflated) as? [String: Any],
                  (envelope["kind"] as? String) == "event",
                  let topic = envelope["topic"] as? String,
                  topic == "terminal.render_grid",
                  let payload = envelope["payload"]
            else { fatalError("bad envelope") }
            let payloadData = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try JSONDecoder().decode(
                MobileTerminalRenderGridFrame.self, from: payloadData
            )
            blackHole(decoded)
        }
    }

    /// Phone receive, raw-channel path: header parse + typed decode of the
    /// payload slice. `compressed` mirrors a channel that carries zlib
    /// payloads with the same 0x01-magic convention.
    private static func phoneReceiveRaw(wire: Data, compressed: Bool) throws {
        var offset = wire.startIndex
        let version = wire[offset]; offset += 1
        let flags = wire[offset]; offset += 1
        let sidLen = Int(wire[offset]); offset += 1
        let surfaceID = String(decoding: wire[offset..<(offset + sidLen)], as: UTF8.self)
        offset += sidLen
        let anchor = wire[offset]; offset += 1
        var seq: UInt64 = 0
        for _ in 0..<8 { seq = (seq << 8) | UInt64(wire[offset]); offset += 1 }
        guard version == 1, anchor == 1, flags == 0 || flags == 1, !surfaceID.isEmpty
        else { fatalError("bad header") }
        var payload = wire[offset...]
        if compressed {
            guard let inflated = MobileEventFrameCompression.inflatedFrame(
                Data(payload),
                maximumInflatedByteCount: MobileSyncFrameCodec.defaultMaximumFrameByteCount
            ) else { fatalError("inflate failed") }
            payload = inflated[...]
        }
        let decoded = try JSONDecoder().decode(
            MobileTerminalRenderGridFrame.self, from: Data(payload)
        )
        blackHole((decoded, seq))
    }

    // MARK: - The benchmark

    @Test func envelopeOverheadForDeltaAndFullFrames() throws {
        let cases: [(label: String, targetBytes: Int, full: Bool)] = [
            ("8KB delta", 8 * 1024, false),
            ("40KB full", 40 * 1024, true),
        ]
        print("=== RenderGridEnvelopeOverheadBenchmark ===")
        print("host=\(ProcessInfo.processInfo.hostName) cores=\(ProcessInfo.processInfo.activeProcessorCount)")
        for c in cases {
            let frame = try Self.makeFrame(targetBytes: c.targetBytes, full: c.full)
            let payloadJSON = try JSONEncoder().encode(frame)

            // Wire images for each variant, built once (mirrors production:
            // encode/compress once, deliver per connection).
            let jsonWire = try Self.macEmitJSON(payloadJSON: payloadJSON)
            var envelope = Data(#"{"kind":"event","topic":"terminal.render_grid","payload":"#.utf8)
            envelope.append(payloadJSON)
            envelope.append(UInt8(ascii: "}"))
            guard let compressedEnvelope = MobileEventFrameCompression.compressedPayload(for: envelope) else {
                Issue.record("compression unavailable"); return
            }
            let jsonWireCompressed = try MobileSyncFrameCodec.encodeFrame(compressedEnvelope)
            let rawWire = Self.macEmitRaw(
                payloadJSON: payloadJSON,
                surfaceID: frame.surfaceID,
                seq: frame.stateSeq
            )
            guard let compressedPayload = MobileEventFrameCompression.compressedPayload(for: payloadJSON) else {
                Issue.record("compression unavailable"); return
            }
            let rawWireCompressed = Self.macEmitRaw(
                payloadJSON: compressedPayload,
                surfaceID: frame.surfaceID,
                seq: frame.stateSeq
            )

            // Mac-side emit cost.
            let macJSON = try Self.measure {
                Self.blackHole(try Self.macEmitJSON(payloadJSON: payloadJSON))
            }
            let macRaw = Self.measure {
                Self.blackHole(Self.macEmitRaw(
                    payloadJSON: payloadJSON,
                    surfaceID: frame.surfaceID,
                    seq: frame.stateSeq
                ))
            }

            // Phone-side receive cost.
            let phoneJSON = try Self.measure { try Self.phoneReceiveJSON(wire: jsonWire) }
            let phoneJSONZ = try Self.measure { try Self.phoneReceiveJSON(wire: jsonWireCompressed) }
            let phoneRaw = try Self.measure { try Self.phoneReceiveRaw(wire: rawWire, compressed: false) }
            let phoneRawZ = try Self.measure { try Self.phoneReceiveRaw(wire: rawWireCompressed, compressed: true) }

            let winPlain = phoneJSON.p50 + macJSON.p50 - phoneRaw.p50 - macRaw.p50
            let winZ = phoneJSONZ.p50 + macJSON.p50 - phoneRawZ.p50 - macRaw.p50
            print("--- \(c.label): payload=\(payloadJSON.count)B wire(json)=\(jsonWire.count)B wire(json+zlib)=\(jsonWireCompressed.count)B wire(raw)=\(rawWire.count)B wire(raw+zlib)=\(rawWireCompressed.count)B")
            print(String(format: "mac emit    json=%.1fus (p50 %.1f)   raw=%.1fus (p50 %.1f)", macJSON.mean, macJSON.p50, macRaw.mean, macRaw.p50))
            print(String(format: "phone recv  json=%.1fus (p50 %.1f)   raw=%.1fus (p50 %.1f)", phoneJSON.mean, phoneJSON.p50, phoneRaw.mean, phoneRaw.p50))
            print(String(format: "phone recv (zlib wire)  json=%.1fus (p50 %.1f)   raw=%.1fus (p50 %.1f)", phoneJSONZ.mean, phoneJSONZ.p50, phoneRawZ.mean, phoneRawZ.p50))
            print(String(format: "CHANNEL WIN per frame: plain=%.1fus  zlib=%.1fus", winPlain, winZ))
        }
    }
}
