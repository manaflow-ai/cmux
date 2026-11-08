/// Which scenes the AppKit renderer (``AppSceneNativeView``) draws. A list section built from the kit's
/// list pieces (stacks, rows, text, icons, badges, empty states, panels, buttons) draws natively; a
/// scene with a control or prop the AppKit renderer does not draw yet (a text field, toggle, slider,
/// menu button, shape, image, or a free-form frame, fill or border) keeps the SwiftUI renderer
/// (plans/cmux-next/no-swiftui-DESIGN.md: those ports come next).
extension AppScene {
    static let nativeNodeTypes: Set<AppSceneNodeType> = [
        .vStack, .lazyVStack, .group, .forEach, .reorderable, .hStack,
        .text, .icon, .row, .badge, .emptyState, .divider, .spacer, .button, .panel,
    ]
    /// Decoration props only the SwiftUI renderer draws.
    static let swiftUIOnlyProps: Set<String> = ["frame", "background", "borderColor", "hoverBackground", "rotation", "cornerRadius"]

    /// True when every node under the root is one the AppKit renderer draws (an empty scene too).
    var isNativelyRenderable: Bool {
        guard let root else { return true }
        var stack = [root]
        var seen = Set<String>()
        while let id = stack.popLast() {
            guard seen.insert(id).inserted, let node = nodes[id] else { continue }
            guard Self.nativeNodeTypes.contains(node.type), Self.swiftUIOnlyProps.isDisjoint(with: node.props.keys) else { return false }
            stack += node.children
        }
        return true
    }
}
