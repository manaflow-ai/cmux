// SPDX-License-Identifier: MIT

/// Payload for ``ScreenReadResult/text(_:)`` — rendered UTF-8 plus the
/// minimum metadata a client needs (cols/rows/altScreen/title).
public struct TextScreenPayload: Hashable, Sendable, Codable {
    /// Number of columns in the source grid.
    public let cols: Int
    /// Number of rows in the source grid.
    public let rows: Int
    /// Whether the alt screen is currently active.
    public let altScreen: Bool
    /// Window/tab title for the surface, if any.
    public let title: String?
    /// Rendered UTF-8 text for the requested region.
    public let text: String

    /// Creates a text payload.
    public init(cols: Int, rows: Int, altScreen: Bool, title: String?, text: String) {
        self.cols = cols
        self.rows = rows
        self.altScreen = altScreen
        self.title = title
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case altScreen = "alt_screen"
        case title, text
    }
}
