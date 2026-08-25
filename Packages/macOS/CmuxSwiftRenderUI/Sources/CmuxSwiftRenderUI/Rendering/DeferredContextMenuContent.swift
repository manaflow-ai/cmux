import CmuxSwiftRender
import SwiftUI

/// Bridges a deferred interpreter payload to SwiftUI's own lazy menu builder.
/// Constructing this view is cheap; the retained menu nodes are materialized
/// only when SwiftUI asks for the context-menu content.
struct DeferredContextMenuContent: View {
    let modifier: RenderModifier

    var body: some View {
        // The surrounding context-menu closure is escaping and lazy, so this
        // walk starts only when SwiftUI asks for the presented menu's body.
        let children = modifier.materializedChildren()
        if children.count == 1 {
            RenderNodeView(node: children[0])
        } else {
            ZStack {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    RenderNodeView(node: child)
                }
            }
        }
    }
}
