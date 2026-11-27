import SwiftUI

struct ResizeGripperRepresentable: NSViewRepresentable {
    let onBegin: () -> (CGFloat, CGFloat)
    let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    func updateNSView(_ nsView: ResizeGripperNSView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}
