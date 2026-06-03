import Foundation

/// One argument of a ``RenderModifier``: an optional label and a resolved
/// string value (evaluated where possible, else the source token like
/// `.infinity` or `.leading`).
public struct ModifierArg: Sendable, Equatable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// A modifier applied to a ``RenderNode`` (e.g. `.frame(maxWidth: .infinity)`),
/// captured with its labeled argument list so multi-argument modifiers like
/// `.frame` can be applied precisely.
public struct RenderModifier: Sendable, Equatable {
    public let name: String
    public let args: [ModifierArg]

    public init(name: String, args: [ModifierArg] = []) {
        self.name = name
        self.args = args
    }

    /// The first unlabeled argument value (or the first argument), for
    /// single-argument modifiers like `.padding(8)` or `.foregroundColor(.blue)`.
    public var firstValue: String? {
        (args.first(where: { $0.label == nil }) ?? args.first)?.value
    }

    /// The value of the argument with `label`, if present.
    public func value(_ label: String) -> String? {
        args.first { $0.label == label }?.value
    }
}

/// A single command captured from a `Button`'s action closure.
///
/// The interpreter records the call shape; a host runtime executes it. The
/// `cmux` case maps onto cmux's socket command dispatcher (`method` + string
/// arguments), giving interpreted buttons the breadth of the cmux CLI.
public enum ActionCommand: Sendable, Equatable {
    /// A cmux command: a dispatcher method plus named string params, e.g.
    /// `cmux("workspace.select", workspace_id: w.id)` →
    /// `.cmux("workspace.select", ["workspace_id": "<uuid>"])`. Maps directly
    /// onto the socket command protocol (`{"method","params"}`).
    case cmux(method: String, params: [String: String])
    case log(String)
    /// Opens a URL (host runs it, e.g. via the workspace opener).
    case openURL(String)
}

/// The captured behavior of a `Button`, evaluated when the button is tapped
/// by a host runtime.
public struct ButtonAction: Sendable, Equatable {
    public let commands: [ActionCommand]

    public init(commands: [ActionCommand]) {
        self.commands = commands
    }
}

/// Describes how a `.reorderable` list persists a drag-and-drop reorder: the
/// dispatcher `method` to run on drop, the param names for the moved item's id
/// and its target index, and the ordered item ids (parallel to the node's
/// children). The host runs `method` with `[idParam: movedId, indexParam:
/// targetIndex]`, so for workspaces the cmux `workspace.reorder` command both
/// reorders and persists.
public struct ReorderSpec: Sendable, Equatable {
    public let method: String
    public let idParam: String
    public let indexParam: String
    public let itemIds: [String]

    public init(method: String, idParam: String, indexParam: String, itemIds: [String]) {
        self.method = method
        self.idParam = idParam
        self.indexParam = indexParam
        self.itemIds = itemIds
    }
}

/// The intermediate representation an interpreted Swift `View` expression
/// lowers to, before a SwiftUI bridge turns it into real views.
///
/// This IR is the leaf-bridge boundary: the interpreter handles the Swift
/// *language* (calls, closures, later loops/state), and a thin SwiftUI
/// layer maps each ``Kind`` to the real compiled view initializer. The set
/// of kinds is the framework bridge that grows over time; the language
/// coverage is what makes the approach general.
public struct RenderNode: Sendable, Equatable {
    /// The view primitive this node represents.
    public enum Kind: String, Sendable {
        case vstack
        case hstack
        case zstack
        /// A horizontally resizable split: children are columns separated by
        /// a draggable divider. The host owns the split fraction.
        case hsplit
        /// A vertical list whose rows can be drag-and-drop reordered; the
        /// drop is persisted via ``ReorderSpec``.
        case reorderable
        case text
        case button
        case image
        case spacer
        case divider
        // Shape views (fillable via `.fill`/`.foregroundColor`, sizable via `.frame`).
        case rectangle
        case roundedRectangle
        case capsule
        case circle
    }

    public var kind: Kind
    public var text: String?
    /// SF Symbol name for `.image` nodes (`Image(systemName:)`).
    public var systemName: String?
    public var spacing: Double?
    /// Corner radius for `.roundedRectangle` (`RoundedRectangle(cornerRadius:)`).
    public var cornerRadius: Double?
    public var children: [RenderNode]
    public var modifiers: [RenderModifier]
    public var action: ButtonAction?
    /// Drag-and-drop reorder spec for `.reorderable` nodes.
    public var reorder: ReorderSpec?

    public init(
        kind: Kind,
        text: String? = nil,
        systemName: String? = nil,
        spacing: Double? = nil,
        cornerRadius: Double? = nil,
        children: [RenderNode] = [],
        modifiers: [RenderModifier] = [],
        action: ButtonAction? = nil,
        reorder: ReorderSpec? = nil
    ) {
        self.kind = kind
        self.text = text
        self.systemName = systemName
        self.spacing = spacing
        self.cornerRadius = cornerRadius
        self.children = children
        self.modifiers = modifiers
        self.action = action
        self.reorder = reorder
    }
}
