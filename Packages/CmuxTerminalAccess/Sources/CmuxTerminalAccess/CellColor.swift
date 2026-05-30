// SPDX-License-Identifier: MIT

import Foundation

/// Foreground/background color for a cell.
///
/// Three forms:
/// - ``default``: the surface's default color (encoded as `"default"`).
/// - ``palette(_:)``: indexed 256-color palette entry (encoded as
///   `{"palette":N}`).
/// - ``rgb(r:g:b:)``: 24-bit truecolor (encoded as `{"rgb":{"r":..,"g":..,"b":..}}`).
public enum CellColor: Sendable, Codable, Hashable {
    /// The surface's default color.
    case `default`
    /// An indexed 256-color palette entry.
    case palette(UInt8)
    /// A 24-bit RGB truecolor value.
    case rgb(r: UInt8, g: UInt8, b: UInt8)

    private enum Keys: String, CodingKey { case palette, rgb }
    private struct RGB: Codable, Hashable { let r: UInt8; let g: UInt8; let b: UInt8 }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self), s == "default" {
            self = .default
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        if let p = try c.decodeIfPresent(UInt8.self, forKey: .palette) {
            self = .palette(p)
            return
        }
        if let rgb = try c.decodeIfPresent(RGB.self, forKey: .rgb) {
            self = .rgb(r: rgb.r, g: rgb.g, b: rgb.b)
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "bad CellColor"))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .default:
            var c = encoder.singleValueContainer()
            try c.encode("default")
        case .palette(let p):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(p, forKey: .palette)
        case .rgb(let r, let g, let b):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(RGB(r: r, g: g, b: b), forKey: .rgb)
        }
    }
}
