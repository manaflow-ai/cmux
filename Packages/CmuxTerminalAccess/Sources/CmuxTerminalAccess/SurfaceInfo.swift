// SPDX-License-Identifier: MIT

import Foundation

/// Snapshot of a single surface's transport-visible metadata.
///
/// Returned by ``SurfaceProvider`` (D1). A value type so the service
/// can hold it without a live AppKit/ghostty reference. Fields mirror
/// the JSON surface descriptor the HTTP layer returns.
public struct SurfaceInfo: Hashable, Sendable {
    /// Stable, transport-neutral handle.
    public let handle: SurfaceHandle
    /// Persistent surface identifier.
    public let uuid: UUID
    /// Workspace handle string the surface belongs to.
    public let workspaceRef: String
    /// Optional terminal title (may be `nil` before the PTY sets one).
    public let title: String?
    /// Grid width in cells.
    public let cols: Int
    /// Grid height in cells.
    public let rows: Int
    /// `true` when the terminal is showing the alt screen (e.g. while
    /// `vim`/`less` is in the foreground).
    public let altScreen: Bool
    /// Whether the surface currently holds focus in the cmux UI.
    public let focused: Bool
    /// `true` when ghostty exposes semantic (prompt/output) metadata
    /// for this surface.
    public let semanticAvailable: Bool

    /// Creates a snapshot. All fields are immutable for the lifetime
    /// of the value.
    public init(
        handle: SurfaceHandle,
        uuid: UUID,
        workspaceRef: String,
        title: String?,
        cols: Int,
        rows: Int,
        altScreen: Bool,
        focused: Bool,
        semanticAvailable: Bool
    ) {
        self.handle = handle
        self.uuid = uuid
        self.workspaceRef = workspaceRef
        self.title = title
        self.cols = cols
        self.rows = rows
        self.altScreen = altScreen
        self.focused = focused
        self.semanticAvailable = semanticAvailable
    }
}
