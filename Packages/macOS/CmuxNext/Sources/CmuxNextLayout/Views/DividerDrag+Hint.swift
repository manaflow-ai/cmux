import AppKit
import CmuxNextDesign

/// The on-screen hint of the modifier mode a drag is in (resize-modifiers.md): a toast at the
/// bottom of the window, shown while a key changes what the drag does and gone on release. It names
/// only modes that do something for this handle (Option on a docked column's edge says nothing).
extension DividerDrag {
    static let hintToastID = "layout.resizeMode"

    /// The hint for `drag`'s keys and handle; nil when the drag is a plain one.
    static func hint(for drag: DividerDragState) -> String? {
        let keys = drag.modifiers
        var parts: [String] = []
        switch drag.kind {
        case let .split(id):
            if keys.push, drag.push != nil { parts.append(LayoutStrings.resizeModePush) }
            if keys.all, let node = drag.tree?.node(for: id), node.a.isSplit(along: node.axis) || node.b.isSplit(along: node.axis) {
                parts.append(LayoutStrings.resizeModeEven)
            }
        case let .columnEdge(id):
            if let strip = drag.strip {
                if keys.all, strip.columns.count > 1 {
                    parts.append(LayoutStrings.resizeModeAllColumns)
                } else if keys.push, strip.next(after: id) != nil {
                    parts.append(LayoutStrings.resizeModeTrade)
                }
            }
        case .rowEdge:
            return nil
        }
        if keys.fine {
            parts.append(LayoutStrings.resizeModeFine)
        } else if keys.snap {
            parts.append(LayoutStrings.resizeModeSnap)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// `drag` with its hint brought up to date: a new hint replaces the one showing, none hides it.
    /// A window that is not on screen shows none.
    func showingHint(_ drag: DividerDragState) -> DividerDragState {
        var drag = drag
        let text = Self.hint(for: drag)
        guard text != drag.hint else { return drag }
        drag.hint = text
        drag.hintToast?.dismiss()
        drag.hintToast = nil
        if let text, let window = screen.window, window.isVisible {
            drag.hintToast = toasts.show(CmuxToast(id: Self.hintToastID, message: text, duration: .seconds(30)), in: window)
        }
        return drag
    }
}

extension SplitNode {
    /// Whether this node splits along `axis` (a chain a divider's Command drag evens).
    nonisolated func isSplit(along axis: SplitAxis) -> Bool {
        if case let .split(_, nodeAxis, _, _, _) = self { return nodeAxis == axis }
        return false
    }
}
