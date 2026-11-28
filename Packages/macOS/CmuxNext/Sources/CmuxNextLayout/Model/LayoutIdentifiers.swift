import Foundation

/// A string-backed identifier tagged with the kind of object it names, so a
/// `PaneID` can never be passed where a `SplitID` is expected.
///
/// The App layer fills these from daemon durable ids (`resource_id`, the v8
/// `SplitId`, `tab_resource_id`). Numeric daemon handles are valid for one
/// daemon generation only and should not be used here.
public nonisolated struct LayoutIdentifier<Tag>: RawRepresentable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible, Comparable
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Phantom tags for `LayoutIdentifier`, namespaced so the file stays one type.
public nonisolated enum LayoutTag {
    public enum Pane {}
    public enum Split {}
    public enum Column {}
    public enum Row {}
    public enum Screen {}
    public enum Tab {}
    public enum Transaction {}
}

/// A leaf of a split tree. Hosts one App-provided view (terminal, browser, tab strip).
public typealias PaneID = LayoutIdentifier<LayoutTag.Pane>
/// An interior split node. Divider identity; maps to the daemon `SplitId`.
public typealias SplitID = LayoutIdentifier<LayoutTag.Split>
/// A scrollable column. Maps to the daemon `columns[].id`.
public typealias ColumnID = LayoutIdentifier<LayoutTag.Column>
/// A row of a column. Maps to the daemon `columns[].rows[].id`.
public typealias RowID = LayoutIdentifier<LayoutTag.Row>
/// A screen (a window inside a workspace) of a workspace.
public typealias ScreenID = LayoutIdentifier<LayoutTag.Screen>
/// A tab placement being dragged onto the layout.
public typealias TabID = LayoutIdentifier<LayoutTag.Tab>
/// One continuous gesture (divider or column drag). Maps to the daemon
/// `transaction` field so the whole drag coalesces into one undo entry.
public typealias LayoutTransactionID = LayoutIdentifier<LayoutTag.Transaction>

extension LayoutIdentifier where Tag == LayoutTag.Transaction {
    /// A fresh unique transaction id.
    public static func make() -> Self { Self(UUID().uuidString.lowercased()) }
}
