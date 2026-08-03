public import Foundation

/// Producer-facing vertical placement accepted by `surface.overlay.set`.
public enum ControlSurfaceOverlayAnchor: String, Equatable, Sendable {
    case viewportTop
    case scrollbackTop
}

/// Producer-facing horizontal placement accepted by `surface.overlay.set`.
public enum ControlSurfaceOverlayAlignment: String, Equatable, Sendable {
    case left
    case center
    case right
}

/// Parsed input for one overlay upsert.
public struct ControlSurfaceOverlaySetInputs: Equatable, Sendable {
    public let id: String
    public let text: String
    public let anchor: ControlSurfaceOverlayAnchor
    public let alignment: ControlSurfaceOverlayAlignment

    public init(
        id: String,
        text: String,
        anchor: ControlSurfaceOverlayAnchor,
        alignment: ControlSurfaceOverlayAlignment
    ) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.alignment = alignment
    }
}

/// One shared mutation/read path for all overlay entrypoints.
public enum ControlSurfaceOverlayAction: Equatable, Sendable {
    case list
    case set(ControlSurfaceOverlaySetInputs)
    case remove(id: String)
    case clear
}

/// A socket-safe snapshot of one resolved terminal overlay.
public struct ControlSurfaceOverlaySnapshot: Equatable, Sendable {
    public let id: String
    public let text: String
    public let anchor: ControlSurfaceOverlayAnchor
    public let alignment: ControlSurfaceOverlayAlignment
    public let scrollbackRow: Int?
    public let rowSpaceRevision: UInt64?

    public init(
        id: String,
        text: String,
        anchor: ControlSurfaceOverlayAnchor,
        alignment: ControlSurfaceOverlayAlignment,
        scrollbackRow: Int? = nil,
        rowSpaceRevision: UInt64? = nil
    ) {
        self.id = id
        self.text = text
        self.anchor = anchor
        self.alignment = alignment
        self.scrollbackRow = scrollbackRow
        self.rowSpaceRevision = rowSpaceRevision
    }
}

/// Validation discriminators returned by the app after core model validation.
public enum ControlSurfaceOverlayValidationError: Equatable, Sendable {
    case invalidIdentifier
    case emptyText
    case textTooLong(maxUTF8Bytes: Int)
    case invalidAnchor(String)
    case invalidAlignment(String)
}

/// Localized messages supplied by the app bundle for overlay command failures.
public struct ControlSurfaceOverlayStrings: Equatable, Sendable {
    public let tabManagerUnavailable: String
    public let workspaceNotFound: String
    public let surfaceNotFound: String
    public let noFocusedSurface: String
    public let surfaceNotTerminal: String
    public let invalidIdentifier: String
    public let emptyText: String
    public let textTooLongFormat: String
    public let invalidAnchorFormat: String
    public let invalidAlignmentFormat: String
    public let scrollbackUnavailable: String

    public init(
        tabManagerUnavailable: String,
        workspaceNotFound: String,
        surfaceNotFound: String,
        noFocusedSurface: String,
        surfaceNotTerminal: String,
        invalidIdentifier: String,
        emptyText: String,
        textTooLongFormat: String,
        invalidAnchorFormat: String,
        invalidAlignmentFormat: String,
        scrollbackUnavailable: String
    ) {
        self.tabManagerUnavailable = tabManagerUnavailable
        self.workspaceNotFound = workspaceNotFound
        self.surfaceNotFound = surfaceNotFound
        self.noFocusedSurface = noFocusedSurface
        self.surfaceNotTerminal = surfaceNotTerminal
        self.invalidIdentifier = invalidIdentifier
        self.emptyText = emptyText
        self.textTooLongFormat = textTooLongFormat
        self.invalidAnchorFormat = invalidAnchorFormat
        self.invalidAlignmentFormat = invalidAlignmentFormat
        self.scrollbackUnavailable = scrollbackUnavailable
    }
}

/// The resolved target and action result for `surface.overlay.*`.
public enum ControlSurfaceOverlayResolution: Equatable, Sendable {
    case tabManagerUnavailable
    case workspaceNotFound
    case surfaceNotFound
    case noFocusedSurface
    case surfaceNotTerminal(UUID)
    case validationFailed(ControlSurfaceOverlayValidationError)
    case scrollbackUnavailable(UUID)
    case listed(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID,
        overlays: [ControlSurfaceOverlaySnapshot]
    )
    case set(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID,
        overlay: ControlSurfaceOverlaySnapshot
    )
    case removed(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID,
        overlayID: String,
        removed: Bool
    )
    case cleared(
        windowID: UUID?,
        workspaceID: UUID,
        surfaceID: UUID,
        removedCount: Int
    )
}
