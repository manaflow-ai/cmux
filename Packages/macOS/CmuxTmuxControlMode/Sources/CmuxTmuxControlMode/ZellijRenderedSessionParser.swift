import Foundation

/// A record from `zellij subscribe --format json --ansi`.
public enum ZellijRenderedSessionEvent: Equatable, Sendable {
    /// `viewport` is a complete rendered pane viewport. `scrollback` is
    /// present when the subscription requested it, normally only in the
    /// initial record.
    case update(paneID: String, viewport: [String], scrollback: [String]?, isInitial: Bool)
    /// The subscribed pane no longer exists.
    case closed(paneID: String)
    /// The JSON-lines contract was violated. The caller must discard the
    /// subscription because a later frame cannot be ordered safely.
    case protocolError(reason: String)
}

/// Incremental decoder for Zellij's documented JSON subscription stream.
/// Unlike tmux control mode, this stream carries rendered lines rather than
/// terminal escape bytes. The parser therefore keeps the line and frame
/// boundaries explicit and never treats arbitrary JSON text as terminal data.
public struct ZellijRenderedSessionParser: Sendable {
    public static let defaultMaximumRecordBytes = 16 * 1024 * 1024
    public static let defaultMaximumFrameBytes = 16 * 1024 * 1024

    private var pending = Data()
    private var failed = false
    private let maximumRecordBytes: Int
    private let maximumFrameBytes: Int

    public init(
        maximumRecordBytes: Int = Self.defaultMaximumRecordBytes,
        maximumFrameBytes: Int = Self.defaultMaximumFrameBytes
    ) {
        self.maximumRecordBytes = max(1, maximumRecordBytes)
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }

    public mutating func consume(_ bytes: [UInt8]) -> [ZellijRenderedSessionEvent] {
        guard !bytes.isEmpty, !failed else { return [] }
        var events: [ZellijRenderedSessionEvent] = []
        for byte in bytes {
            pending.append(byte)
            if pending.count > maximumRecordBytes + 1 {
                return fail("zellij subscription record exceeded \(maximumRecordBytes) bytes", into: &events)
            }
            guard byte == 0x0A else { continue }
            let line = Data(pending.dropLast())
            pending.removeAll(keepingCapacity: true)
            switch Self.decode(line: line, maximumFrameBytes: maximumFrameBytes) {
            case .event(let event):
                events.append(event)
            case .ignored:
                break
            case .invalid(let reason):
                return fail(reason, into: &events)
            }
        }
        return events
    }

    public mutating func finish() -> [ZellijRenderedSessionEvent] {
        guard !failed, !pending.isEmpty else { return [] }
        let line = pending
        pending.removeAll(keepingCapacity: false)
        switch Self.decode(line: line, maximumFrameBytes: maximumFrameBytes) {
        case .event(let event):
            return [event]
        case .ignored:
            return []
        case .invalid(let reason):
            failed = true
            return [.protocolError(reason: reason)]
        }
    }

    private mutating func fail(
        _ reason: String,
        into events: inout [ZellijRenderedSessionEvent]
    ) -> [ZellijRenderedSessionEvent] {
        failed = true
        pending.removeAll(keepingCapacity: false)
        events.append(.protocolError(reason: reason))
        return events
    }

    private struct Record: Decodable {
        let event: String?
        let paneID: String?
        let viewport: [String]?
        let scrollback: [String]?
        let isInitial: Bool?

        enum CodingKeys: String, CodingKey {
            case event
            case paneID = "pane_id"
            case viewport
            case scrollback
            case isInitial = "is_initial"
        }
    }

    private enum DecodeResult {
        case event(ZellijRenderedSessionEvent)
        case ignored
        case invalid(String)
    }

    private static func decode(line: Data, maximumFrameBytes: Int) -> DecodeResult {
        let text = String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignored }

        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: Data(text.utf8))
        } catch {
            return .invalid("invalid zellij subscription JSON: \(error.localizedDescription)")
        }

        guard let event = record.event else {
            return .invalid("zellij subscription record has no event")
        }
        switch event {
        case "pane_update":
            guard let paneID = record.paneID,
                  !paneID.isEmpty,
                  let viewport = record.viewport,
                  let isInitial = record.isInitial else {
                return .invalid("zellij pane_update is missing required fields")
            }
            let scrollback = record.scrollback
            let frameBytes = viewport.reduce(0) { $0 + $1.utf8.count }
                + (scrollback?.reduce(0) { $0 + $1.utf8.count } ?? 0)
            guard frameBytes <= maximumFrameBytes else {
                return .invalid("zellij pane_update exceeded \(maximumFrameBytes) bytes")
            }
            guard viewport.allSatisfy(Self.isRenderedLine)
                    && (scrollback ?? []).allSatisfy(Self.isRenderedLine)
            else {
                return .invalid("zellij pane_update contains a line break")
            }
            return .event(.update(
                paneID: paneID,
                viewport: viewport,
                scrollback: scrollback,
                isInitial: isInitial
            ))
        case "pane_closed":
            guard let paneID = record.paneID, !paneID.isEmpty else {
                return .invalid("zellij pane_closed is missing pane_id")
            }
            return .event(.closed(paneID: paneID))
        default:
            // The subscribe command currently emits only the two records
            // above. Preserve forward compatibility for valid informational
            // records while refusing malformed JSON.
            return .ignored
        }
    }

    private static func isRenderedLine(_ line: String) -> Bool {
        !line.contains("\n") && !line.contains("\r")
    }
}
