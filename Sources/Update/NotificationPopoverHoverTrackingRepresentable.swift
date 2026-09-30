import SwiftUI

struct HoverTrackingRepresentable: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}
