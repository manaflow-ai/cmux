import AppKit
import SwiftUI

/// Embeds the native Ports help button in a SwiftUI section header.
@MainActor
struct CloudVPNSetupButtonRepresentable: NSViewRepresentable {
    let setup: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> CloudVPNSetupButton {
        let button = CloudVPNSetupButton(frame: .zero, presentation: .helpIcon)
        button.setup = setup
        return button
    }

    func updateNSView(_ nsView: CloudVPNSetupButton, context: Context) {
        nsView.setup = setup
    }
}
