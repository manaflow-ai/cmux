import Foundation

/// One record emitted by `herdr terminal session control`.
public enum HerdrControlModeEvent: Equatable, Sendable {
    /// ANSI bytes for the rendered terminal. `full` identifies Herdr's
    /// initial replacement frame; callers can also use the first frame when
    /// talking to older Herdr versions that omit the field.
    case frame(bytes: [UInt8], sequence: UInt64?, width: UInt16?, height: UInt16?, full: Bool)
    /// The server closed the controlled terminal stream.
    case closed(reason: String?)
    /// The stdout stream was not valid Herdr control JSON. The caller must
    /// close the transport because continuing would make frame ordering
    /// unverifiable.
    case protocolError(reason: String)
}

/// Incremental JSON-lines decoder for Herdr's direct terminal-control stream.
/// It accepts arbitrary pipe chunking and ignores unrelated diagnostics so a
/// valid control record is never lost because stderr was redirected by a
/// wrapper.
public struct HerdrControlModeParser: Sendable {
    private var pending = Data()
    private var failed = false
    private let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 16 * 1024 * 1024) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    public mutating func consume(_ bytes: [UInt8]) -> [HerdrControlModeEvent] {
        guard !bytes.isEmpty, !failed else { return [] }
        var events: [HerdrControlModeEvent] = []
        for byte in bytes {
            pending.append(byte)
            if pending.count > maximumLineBytes + 1 {
                failed = true
                pending.removeAll(keepingCapacity: false)
                events.append(.protocolError(reason: "herdr control record exceeded \(maximumLineBytes) bytes"))
                return events
            }
            guard byte == 0x0A else { continue }
            let line = pending.dropLast()
            pending.removeAll(keepingCapacity: true)
            switch Self.decode(line: line) {
            case .event(let event):
                events.append(event)
            case .ignored:
                break
            case .invalid(let reason):
                failed = true
                pending.removeAll(keepingCapacity: false)
                events.append(.protocolError(reason: reason))
                return events
            }
        }
        return events
    }

    /// Flushes a final line when a test or transport closes without a trailing
    /// newline. Production Herdr emits newline-delimited records, but accepting
    /// the final record makes EOF handling deterministic.
    public mutating func finish() -> [HerdrControlModeEvent] {
        guard !pending.isEmpty, !failed else { return [] }
        let line = pending
        pending.removeAll(keepingCapacity: false)
        switch Self.decode(line: line) {
        case .event(let event): return [event]
        case .ignored: return []
        case .invalid(let reason):
            failed = true
            return [.protocolError(reason: reason)]
        }
    }

    private struct Record: Decodable {
        let type: String
        let bytes: String?
        let seq: UInt64?
        let sequence: UInt64?
        let width: UInt16?
        let height: UInt16?
        let cols: UInt16?
        let rows: UInt16?
        let full: Bool?
        let reason: String?
    }

    private enum DecodeResult {
        case event(HerdrControlModeEvent)
        case ignored
        case invalid(String)
    }

    private static func decode(line: Data) -> DecodeResult {
        let text = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(text.utf8))
        } catch {
            return .invalid("invalid herdr control JSON: \(error.localizedDescription)")
        }

        switch record.type {
        case "terminal.frame":
            guard let encoded = record.bytes,
                  let data = Data(base64Encoded: encoded)
            else { return .invalid("herdr terminal.frame has invalid base64 bytes") }
            return .event(.frame(
                bytes: Array(data),
                sequence: record.seq ?? record.sequence,
                width: record.width ?? record.cols,
                height: record.height ?? record.rows,
                full: record.full ?? false
            ))
        case "terminal.closed":
            return .event(.closed(reason: record.reason))
        default:
            // Herdr may add informational records to stdout. They do not
            // affect the frame stream and are safe to ignore after decoding.
            return .ignored
        }
    }
}
