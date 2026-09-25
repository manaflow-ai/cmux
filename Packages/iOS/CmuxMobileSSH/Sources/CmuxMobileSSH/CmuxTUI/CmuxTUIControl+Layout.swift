import Foundation

/// `new-screen` / `new-tab` result.
struct CmuxTUISurfaceResultWire: Decodable {
    var surface: Int
}

// MARK: - Screens and tabs

extension CmuxTUIControl {
    /// Creates a screen (one pane, one terminal tab) in the workspace with
    /// numeric id `workspace` and returns the new terminal's surface id.
    /// The server makes the new screen its active screen.
    public func newScreen(workspace: Int, cols: Int? = nil, rows: Int? = nil) async throws -> Int {
        var params: [String: CmuxTUIWireValue] = ["workspace": .int(workspace)]
        if let cols, let rows {
            params["cols"] = .int(cols)
            params["rows"] = .int(rows)
        }
        return try await request("new-screen", params, as: CmuxTUISurfaceResultWire.self).surface
    }

    /// Creates a terminal tab in `pane` and returns its surface id. The new
    /// tab inherits the working directory of the pane's active tab.
    public func newTab(pane: Int, cols: Int? = nil, rows: Int? = nil) async throws -> Int {
        var params: [String: CmuxTUIWireValue] = ["pane": .int(pane)]
        if let cols, let rows {
            params["cols"] = .int(cols)
            params["rows"] = .int(rows)
        }
        return try await request("new-tab", params, as: CmuxTUISurfaceResultWire.self).surface
    }
}

// MARK: - Geometry while visible

extension CmuxTUIControl {
    /// Gives up this attachment's geometry authority while keeping its
    /// stream (`release-attached-view-size`). The server hands geometry back
    /// to the owner this attachment displaced (for example a laptop client)
    /// when it still reports a viewport; otherwise the grid stays as it is
    /// until a view claims it again. Returns `false` without sending anything
    /// when the stream has no lease.
    @discardableResult
    public func releaseGeometry(_ attachment: CmuxTUIAttachment) async throws -> Bool {
        guard let lease = attachment.lease, isAttached(surface: attachment.surface) else { return false }
        _ = try await request(
            "release-attached-view-size",
            ["surface": .int(attachment.surface), "lease": .string(lease)],
            as: CmuxTUIOutcomeWire.self
        )
        return true
    }

    /// Reports `cols` x `rows` for the attachment and claims exclusive
    /// geometry authority again (after ``releaseGeometry(_:)``).
    public func claimGeometry(_ attachment: CmuxTUIAttachment, cols: Int, rows: Int) async throws {
        _ = try await resize(attachment, cols: cols, rows: rows)
        try await request(
            "set-client-sizing",
            ["surface": .int(attachment.surface), "enabled": .bool(true), "exclusive": .bool(true)],
            as: CmuxTUIEmpty.self
        )
        // With authority the size report now applies; report once more so a
        // grid that differs from the frozen one resizes the PTY.
        _ = try await resize(attachment, cols: cols, rows: rows)
    }
}
