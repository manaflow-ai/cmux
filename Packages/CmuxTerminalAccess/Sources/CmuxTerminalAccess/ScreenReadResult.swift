// SPDX-License-Identifier: MIT

import Foundation

/// Discriminated result of a ``ScreenReadRequest``. Encoded as
/// `{"format":"text"|"cells", ...}` to match the HTTP wire shape.
public enum ScreenReadResult: Sendable, Codable {
    /// Plain-text rendering of the surface.
    case text(TextScreenPayload)
    /// Structured per-cell grid snapshot.
    case cells(CellGrid)

    private enum Keys: String, CodingKey { case format }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let format = try c.decode(ScreenFormat.self, forKey: .format)
        let single = try decoder.singleValueContainer()
        switch format {
        case .text: self = .text(try single.decode(TextScreenPayload.self))
        case .cells: self = .cells(try single.decode(CellGrid.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let p):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(ScreenFormat.text, forKey: .format)
            try p.encode(to: encoder)
        case .cells(let g):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(ScreenFormat.cells, forKey: .format)
            try g.encode(to: encoder)
        }
    }
}
