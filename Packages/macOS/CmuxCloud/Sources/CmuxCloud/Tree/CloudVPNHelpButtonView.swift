import AppKit
import SwiftUI

/// Keeps native button interaction inside the outline while SwiftUI owns label layout.
@MainActor
struct CloudVPNHelpButtonView: NSViewRepresentable {
    let openSetup: () -> Void

    func makeNSView(context: Context) -> CloudVPNHelpButton {
        CloudVPNHelpButton(frame: .zero)
    }

    func updateNSView(_ button: CloudVPNHelpButton, context: Context) {
        button.openSetup = openSetup
    }
}
