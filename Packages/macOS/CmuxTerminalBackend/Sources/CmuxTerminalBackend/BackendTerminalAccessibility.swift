public import Foundation

/// A UTF-16 range suitable for AppKit accessibility APIs.
public struct BackendTerminalAccessibilityRange: Decodable, Equatable, Sendable {
    public let location: UInt32
    public let length: UInt32
}

/// One semantic terminal cell mapped into the flattened accessibility text.
public struct BackendTerminalAccessibilityCell: Decodable, Equatable, Sendable {
    public let column: UInt16
    public let columnSpan: UInt16
    public let utf16Range: BackendTerminalAccessibilityRange

    private enum CodingKeys: String, CodingKey {
        case column
        case columnSpan = "column_span"
        case utf16Range = "utf16_range"
    }
}

/// One visible retained-screen row and its exact UTF-16/cell mapping.
public struct BackendTerminalAccessibilityLine: Decodable, Equatable, Sendable {
    public let row: UInt64
    public let utf16Range: BackendTerminalAccessibilityRange
    public let cells: [BackendTerminalAccessibilityCell]

    private enum CodingKeys: String, CodingKey {
        case row, cells
        case utf16Range = "utf16_range"
    }
}

/// Canonical cursor projected as a zero-length insertion range.
public struct BackendTerminalAccessibilityCursor: Decodable, Equatable, Sendable {
    public let column: UInt16
    public let row: UInt64
    public let insertionRange: BackendTerminalAccessibilityRange
    public let line: UInt32

    private enum CodingKeys: String, CodingKey {
        case column, row, line
        case insertionRange = "insertion_range"
    }
}

/// One canonical selection and its visible UTF-16 intersections.
public struct BackendTerminalAccessibilitySelection: Decodable, Equatable, Sendable {
    public let text: String
    public let utf16Ranges: [BackendTerminalAccessibilityRange]

    private enum CodingKeys: String, CodingKey {
        case text
        case utf16Ranges = "utf16_ranges"
    }
}

/// One contiguous OSC 8 link inside a visible terminal row.
public struct BackendTerminalAccessibilityLink: Decodable, Equatable, Sendable {
    public let id: String
    public let target: String
    public let utf16Range: BackendTerminalAccessibilityRange
    public let row: UInt64
    public let startColumn: UInt16
    public let endColumn: UInt16

    private enum CodingKeys: String, CodingKey {
        case id, target, row
        case utf16Range = "utf16_range"
        case startColumn = "start_column"
        case endColumn = "end_column"
    }
}

/// Revision-fenced daemon-owned terminal semantics for accessibility.
public struct BackendTerminalAccessibilitySnapshot: Decodable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let surfaceID: SurfaceID
    public let presentationID: PresentationID
    public let presentationGeneration: UInt64
    public let contentSequence: UInt64
    public let terminalRevision: UInt64
    public let contentRevision: UInt64
    public let viewportRevision: UInt64
    public let viewportOffset: UInt64
    public let columns: UInt16
    public let rows: UInt16
    public let text: String
    public let lines: [BackendTerminalAccessibilityLine]
    public let cursor: BackendTerminalAccessibilityCursor?
    public let selections: [BackendTerminalAccessibilitySelection]
    public let links: [BackendTerminalAccessibilityLink]
    public let focused: Bool

    private enum CodingKeys: String, CodingKey {
        case text, lines, cursor, selections, links, focused, columns, rows
        case schemaVersion = "schema_version"
        case surfaceID = "surface_uuid"
        case presentationID = "presentation_id"
        case presentationGeneration = "presentation_generation"
        case contentSequence = "content_sequence"
        case terminalRevision = "terminal_revision"
        case contentRevision = "content_revision"
        case viewportRevision = "viewport_revision"
        case viewportOffset = "viewport_offset"
    }
}

/// Revision-fenced link target returned after daemon revalidation.
public struct BackendTerminalAccessibilityLinkActivation: Decodable, Equatable, Sendable {
    public let target: String
}

/// An OSC 8 target resolved from one exact displayed semantic frame and cell.
public struct BackendTerminalHyperlinkHit: Decodable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let presentationID: PresentationID
    public let presentationGeneration: UInt64
    public let contentSequence: UInt64
    public let terminalRevision: UInt64
    public let contentRevision: UInt64
    public let viewportRevision: UInt64
    public let column: UInt16
    public let row: UInt64
    public let target: String

    private enum CodingKeys: String, CodingKey {
        case column, row, target
        case surfaceID = "surface_uuid"
        case presentationID = "presentation_id"
        case presentationGeneration = "presentation_generation"
        case contentSequence = "content_sequence"
        case terminalRevision = "terminal_revision"
        case contentRevision = "content_revision"
        case viewportRevision = "viewport_revision"
    }
}
