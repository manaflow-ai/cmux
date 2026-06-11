import CmuxSwiftRender
import SwiftUI

/// SPIKE STUB (not for merge): renders a `.textField` node as a real
/// `TextField` backed by view-local `@State`.
///
/// The static ``RenderNode`` IR has no binding concept, so the typed value
/// never round-trips into the interpreter environment; the node's `binding`
/// name is carried for display only. This exists purely to prove input
/// fidelity through the in-process mount: focus ring, caret, typing, and
/// selection all work because the field is native SwiftUI in the host window.
/// Through the remote worker the same node renders but typing cannot reach it
/// (the windowless worker has no key view), which is exactly the contrast the
/// in-process renderer spike demonstrates.
struct TextFieldNodeView: View {
    let node: RenderNode

    @State private var text = ""

    var body: some View {
        // The placeholder comes from the authored sidebar source, not from
        // app UI strings, so it is intentionally not localized.
        TextField(node.text ?? "", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
    }
}
