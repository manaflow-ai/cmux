import CoreFoundation
import Foundation

/// Schema-generated terminal presence anchors used by the Cloud UI.
typealias CloudPresenceAnchor = CloudTuiGenerated.PresenceAnchor
/// Schema-generated highlight mode used by the Cloud UI.
typealias CloudPresenceHighlightMode = CloudTuiGenerated.PresenceHighlightMode
/// Schema-generated terminal presence highlights used by the Cloud UI.
typealias CloudPresenceHighlight = CloudTuiGenerated.PresenceHighlight
/// Schema-generated terminal presence entries used by the Cloud UI.
typealias CloudPresenceEntry = CloudTuiGenerated.PresenceEntry

extension CloudTuiGenerated.OptionalField {
    /// Returns the payload only when an optional field was present with a value.
    var value: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

extension CloudTuiGenerated.PresenceAnchor {
    /// Creates a typed cell anchor from the publisher's terminal grid.
    static func cell(row: Int, col: Int, scrollOffset: UInt64 = 0) -> Self {
        .cell(
            CloudTuiGenerated.PresenceAnchorCell(
                col: UInt32(clamping: max(0, col)),
                row: UInt32(clamping: max(0, row)),
                scrollOffset: scrollOffset == 0 ? .missing : .value(scrollOffset)
            )
        )
    }

    /// Creates a typed point anchor from a browser or display coordinate.
    static func point(x: Double, y: Double) -> Self {
        .point(CloudTuiGenerated.PresenceAnchorPoint(x: x, y: y))
    }

    /// Decodes one schema anchor from a JSON object used by the socket fixture.
    init?(json: Any?) {
        guard let json,
              JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }

    /// Encodes the anchor into a JSON-compatible object for the socket writer.
    var json: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Returns the viewer row after reconciling publisher and viewer scroll offsets.
    func viewerRow(viewerScrollOffset: UInt64, rows: Int) -> Int? {
        guard let shifted = shiftedRow(viewerScrollOffset: viewerScrollOffset),
              shifted >= 0,
              shifted < Int64(rows) else { return nil }
        return Int(shifted)
    }

    /// Returns the signed row delta used by highlight rendering.
    func shiftedRow(viewerScrollOffset: UInt64) -> Int64? {
        guard case let .cell(cell) = self,
              let row = Int64(exactly: cell.row),
              let viewerOffset = Int64(exactly: viewerScrollOffset) else { return nil }
        let publisherOffset: Int64
        switch cell.scrollOffset {
        case .missing, .null:
            publisherOffset = 0
        case let .value(value):
            // A UInt64 above Int64.max cannot be represented in the signed
            // row arithmetic. Treat it as malformed instead of silently
            // dropping the publisher offset and drawing at the wrong row.
            guard let converted = Int64(exactly: value) else { return nil }
            publisherOffset = converted
        }
        let (withViewer, addOverflow) = row.addingReportingOverflow(viewerOffset)
        let (shifted, subtractOverflow) = withViewer.subtractingReportingOverflow(publisherOffset)
        guard !addOverflow, !subtractOverflow else { return nil }
        return shifted
    }
}

extension CloudTuiGenerated.PresenceHighlight {
    /// Decodes one schema highlight from a JSON object used by the socket fixture.
    init?(json: Any?) {
        guard let json,
              JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }

    /// Encodes the highlight into a JSON-compatible object for the socket writer.
    var json: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

extension CloudTuiGenerated.PresenceEntry {
    /// Indicates that this entry is a cleanup event rather than a drawable state.
    var isCleared: Bool { surface == nil }

    /// Decodes one schema presence event from a JSON object used by the socket reader.
    init?(json object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}
