public import Foundation

/// The horizontal edge a terminal overlay follows inside its terminal.
public enum TerminalOverlayHorizontalAlignment: String, CaseIterable, Hashable, Sendable {
    case left
    case center
    case right
}

/// A producer-facing anchor request.
///
/// `scrollbackTop` captures the first visible terminal row when the overlay is
/// created. The resolved overlay then stays attached to that row rather than
/// following the viewport.
public enum TerminalOverlayRequestedAnchor: String, CaseIterable, Hashable, Sendable {
    case viewportTop
    case scrollbackTop
}

/// The resolved vertical anchor of one terminal overlay.
public enum TerminalOverlayAnchor: Equatable, Hashable, Sendable {
    /// Follows the top edge of the visible terminal viewport.
    case viewportTop

    /// Follows one absolute Ghostty row while its row-space revision remains valid.
    case scrollback(row: Int, rowSpaceRevision: UInt64)
}

/// Validation failures for producer-supplied terminal overlay content.
public enum TerminalOverlayValidationError: Error, Equatable, Sendable {
    case invalidIdentifier
    case emptyText
    case textTooLong(maxUTF8Bytes: Int)
}

/// A validated request to create or replace a keyed terminal overlay.
public struct TerminalOverlayRequest: Equatable, Sendable {
    public static let maximumIdentifierUTF8Bytes = 128
    public static let maximumTextUTF8Bytes = 16_384
    public static let defaultMaximumWidthColumns = 72
    public static let defaultMaximumHeightRows = 8

    public let id: String
    public let text: String
    public let anchor: TerminalOverlayRequestedAnchor
    public let horizontalAlignment: TerminalOverlayHorizontalAlignment
    public let maximumWidthColumns: Int
    public let maximumHeightRows: Int

    /// Validates and normalizes producer input.
    ///
    /// Identifier syntax is deliberately portable across socket clients and
    /// config formats. Text retains whitespace and newlines, normalizes CRLF,
    /// and drops control bytes that a passive text renderer cannot represent.
    public init(
        id rawID: String,
        text rawText: String,
        anchor: TerminalOverlayRequestedAnchor = .viewportTop,
        horizontalAlignment: TerminalOverlayHorizontalAlignment = .center,
        maximumWidthColumns: Int = Self.defaultMaximumWidthColumns,
        maximumHeightRows: Int = Self.defaultMaximumHeightRows
    ) throws {
        let id = try Self.validatedIdentifier(rawID)

        let text = Self.normalizedText(rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TerminalOverlayValidationError.emptyText
        }
        guard text.utf8.count <= Self.maximumTextUTF8Bytes else {
            throw TerminalOverlayValidationError.textTooLong(
                maxUTF8Bytes: Self.maximumTextUTF8Bytes
            )
        }

        self.id = id
        self.text = text
        self.anchor = anchor
        self.horizontalAlignment = horizontalAlignment
        self.maximumWidthColumns = max(16, min(200, maximumWidthColumns))
        self.maximumHeightRows = max(1, min(50, maximumHeightRows))
    }

    /// Validates and trims an overlay key for read/remove operations.
    public static func validatedIdentifier(_ rawID: String) throws -> String {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIdentifier(id) else {
            throw TerminalOverlayValidationError.invalidIdentifier
        }
        return id
    }

    /// Resolves the request after the host captures any runtime geometry.
    public func resolved(anchor: TerminalOverlayAnchor) -> TerminalOverlay {
        TerminalOverlay(
            id: id,
            text: text,
            anchor: anchor,
            horizontalAlignment: horizontalAlignment,
            maximumWidthColumns: maximumWidthColumns,
            maximumHeightRows: maximumHeightRows
        )
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty,
              id.utf8.count <= maximumIdentifierUTF8Bytes,
              let first = id.unicodeScalars.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return id.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }

    private static func normalizedText(_ rawText: String) -> String {
        let lineNormalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in lineNormalized.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// One resolved terminal overlay retained by a terminal surface.
public struct TerminalOverlay: Equatable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let anchor: TerminalOverlayAnchor
    public let horizontalAlignment: TerminalOverlayHorizontalAlignment
    public let maximumWidthColumns: Int
    public let maximumHeightRows: Int

    public init(
        id: String,
        text: String,
        anchor: TerminalOverlayAnchor,
        horizontalAlignment: TerminalOverlayHorizontalAlignment,
        maximumWidthColumns: Int,
        maximumHeightRows: Int
    ) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.horizontalAlignment = horizontalAlignment
        self.maximumWidthColumns = maximumWidthColumns
        self.maximumHeightRows = maximumHeightRows
    }
}

/// Ordered keyed storage for overlays owned by one terminal surface.
public struct TerminalOverlayStore: Equatable, Sendable {
    public private(set) var overlays: [TerminalOverlay]

    public init(overlays: [TerminalOverlay] = []) {
        self.overlays = []
        for overlay in overlays {
            upsert(overlay)
        }
    }

    /// Replaces a matching key in place, or appends a new key.
    public mutating func upsert(_ overlay: TerminalOverlay) {
        if let index = overlays.firstIndex(where: { $0.id == overlay.id }) {
            overlays[index] = overlay
        } else {
            overlays.append(overlay)
        }
    }

    /// Removes one keyed overlay.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let index = overlays.firstIndex(where: { $0.id == id }) else {
            return false
        }
        overlays.remove(at: index)
        return true
    }

    /// Removes all overlays and returns the number removed.
    @discardableResult
    public mutating func removeAll() -> Int {
        let count = overlays.count
        overlays.removeAll(keepingCapacity: true)
        return count
    }
}

/// Pure placement calculations shared by the AppKit renderer and package tests.
public enum TerminalOverlayGeometry {
    public static func horizontalOrigin(
        containerWidth: CGFloat,
        overlayWidth: CGFloat,
        alignment: TerminalOverlayHorizontalAlignment,
        margin: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, containerWidth)
        let width = min(max(0, overlayWidth), availableWidth)
        let safeMargin = max(0, min(margin, max(0, (availableWidth - width) / 2)))
        switch alignment {
        case .left:
            return safeMargin
        case .center:
            return max(0, (availableWidth - width) / 2)
        case .right:
            return max(0, availableWidth - width - safeMargin)
        }
    }

    /// Resolves a top-relative Ghostty row into the document view's bottom-up coordinates.
    public static func scrollbackOverlayOriginY(
        documentHeight: CGFloat,
        row: Int,
        totalRows: Int,
        cellHeight: CGFloat,
        topPadding: CGFloat,
        overlayHeight: CGFloat
    ) -> CGFloat? {
        guard row >= 0,
              row < totalRows,
              documentHeight.isFinite,
              cellHeight.isFinite,
              cellHeight > 0,
              topPadding.isFinite,
              overlayHeight.isFinite,
              overlayHeight >= 0 else {
            return nil
        }
        return documentHeight - max(0, topPadding) - CGFloat(row) * cellHeight - overlayHeight
    }
}
