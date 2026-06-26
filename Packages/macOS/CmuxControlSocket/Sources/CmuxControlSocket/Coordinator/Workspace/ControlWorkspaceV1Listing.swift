public import Foundation

/// The byte-faithful rendering of the v1 `list_workspaces` reply, split out of
/// the app-resident ``ControlWorkspaceContext/controlListWorkspacesV1()`` witness
/// so the pure per-row line formatting, separator join, and empty-listing
/// fallback have a tested, `Sendable` home while the live `TabManager` snapshot
/// (enumerating `tabs`, comparing each id to `selectedTabId`) stays app-side.
///
/// The v1 line protocol answers `list_workspaces` with one line per workspace —
/// `"<selected> <index>: <uuid> <title>"`, where `<selected>` is `"*"` for the
/// selected workspace and a single space otherwise — joined by newlines, or the
/// literal `"No workspaces"` when there are none. The fallback keys off the
/// *joined* string being empty (matching the legacy `result.isEmpty` check on the
/// already-joined value), so a lone empty-titled workspace still renders a line
/// rather than collapsing to `"No workspaces"`.
public struct ControlWorkspaceV1Listing: Sendable, Equatable {
    /// One workspace's value snapshot for the v1 listing: the app maps each live
    /// `TabManager` tab into this before formatting, keeping the live-state read
    /// app-side and the line composition pure.
    public struct Row: Sendable, Equatable {
        /// Whether this workspace is the selected one (renders the `"*"` marker).
        public let isSelected: Bool

        /// The workspace's zero-based position in the tab order.
        public let index: Int

        /// The workspace id.
        public let id: UUID

        /// The workspace title, emitted verbatim as the trailing field.
        public let title: String

        /// Creates a v1 listing row from a workspace snapshot.
        ///
        /// - Parameters:
        ///   - isSelected: Whether this workspace is selected.
        ///   - index: The workspace's zero-based tab-order position.
        ///   - id: The workspace id.
        ///   - title: The workspace title.
        public init(isSelected: Bool, index: Int, id: UUID, title: String) {
            self.isSelected = isSelected
            self.index = index
            self.id = id
            self.title = title
        }

        /// The byte-faithful v1 line for this row:
        /// `"<* | space> <index>: <uuid> <title>"`.
        public var line: String {
            "\(isSelected ? "*" : " ") \(index): \(id.uuidString) \(title)"
        }
    }

    /// The workspace rows in tab order.
    public let rows: [Row]

    /// Creates a v1 listing from ordered workspace rows.
    ///
    /// - Parameter rows: The workspace rows in tab order.
    public init(rows: [Row]) {
        self.rows = rows
    }

    /// The byte-faithful v1 `list_workspaces` reply: each row's ``Row/line``
    /// joined by `"\n"`, or `"No workspaces"` when the joined output is empty.
    public var output: String {
        let joined = rows.map(\.line).joined(separator: "\n")
        return joined.isEmpty ? "No workspaces" : joined
    }
}
