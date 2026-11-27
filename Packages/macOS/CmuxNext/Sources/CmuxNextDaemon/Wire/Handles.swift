import Foundation

/// Marker for the entity a numeric handle names.
public protocol DaemonHandleKind: Sendable {}

/// Numeric daemon handle. Numeric ids are valid for one daemon generation only
/// (`cmux-tui/spec/commands.md` "Durable workspace mutation envelope"); model
/// identity must use the durable string ids instead. The phantom `Kind` keeps
/// a pane id from being passed where a surface id is expected.
public struct DaemonHandle<Kind: DaemonHandleKind>: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    CustomStringConvertible, ExpressibleByIntegerLiteral {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(integerLiteral value: UInt64) { self.init(rawValue: value) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { String(rawValue) }
}

/// Handle kinds. Namespaced so each alias below stays one declaration.
public enum HandleKind {
    public enum Workspace: DaemonHandleKind {}
    public enum Screen: DaemonHandleKind {}
    public enum Pane: DaemonHandleKind {}
    public enum Surface: DaemonHandleKind {}
    public enum Split: DaemonHandleKind {}
    public enum Column: DaemonHandleKind {}
    public enum Row: DaemonHandleKind {}
    public enum Notification: DaemonHandleKind {}
    public enum Client: DaemonHandleKind {}
}

/// Generation-scoped numeric workspace id. Use ``WorkspaceKey`` for identity.
public typealias WorkspaceHandle = DaemonHandle<HandleKind.Workspace>
public typealias ScreenID = DaemonHandle<HandleKind.Screen>
public typealias PaneID = DaemonHandle<HandleKind.Pane>
/// A tab's numeric subject id. The raw protocol calls it `surface`.
public typealias SurfaceID = DaemonHandle<HandleKind.Surface>
/// Stable for the lifetime of one split node: ratio changes, focus, and leaf
/// swaps keep it; collapsing the split removes it.
public typealias SplitID = DaemonHandle<HandleKind.Split>
/// Horizontal viewport column id (`Screen.columns[].id`).
public typealias ColumnID = DaemonHandle<HandleKind.Column>
/// A row of a column (`Screen.columns[].rows[].id`, `rows-v1`). Never
/// reused; the compat chain uses it as the split id of rows 2..n.
public typealias RowID = DaemonHandle<HandleKind.Row>
public typealias NotificationID = DaemonHandle<HandleKind.Notification>
public typealias ClientID = DaemonHandle<HandleKind.Client>
