import AppKit
import SwiftUI

/// Bridges the onboarding header to cmux's explicit AppKit window drag path.
@MainActor
struct ComputerUseWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarAccessoryContainerView {
        let view = TitlebarAccessoryContainerView()
        view.setAccessibilityIdentifier("ComputerUseOnboardingDragRegion")
        return view
    }

    func updateNSView(_ nsView: TitlebarAccessoryContainerView, context: Context) {}
}
