#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI host for the mirrored Mac browser frame and its UIKit input surface.
///
/// The displayed frame comes from `state.latestFrame` (installed by the
/// store's long-lived decoder consumer), so remounting this representable can
/// never interrupt the frame pipeline; `updateUIView` re-runs via observation
/// whenever a new frame lands.
struct BrowserStreamSurfaceRepresentable: UIViewRepresentable {
    /// The observable panel state.
    let state: BrowserStreamSurfaceState
    /// RPC action sink.
    let actions: BrowserStreamSurfaceActions

    init(state: BrowserStreamSurfaceState, actions: BrowserStreamSurfaceActions) {
        self.state = state
        self.actions = actions
    }

    func makeCoordinator() -> BrowserStreamSurfaceCoordinator {
        BrowserStreamSurfaceCoordinator(panelID: state.id, actions: actions)
    }

    func makeUIView(context: Context) -> BrowserStreamContentView {
        let view = BrowserStreamContentView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: BrowserStreamContentView, context: Context) {
        view.setInputFocused(state.shouldFocusInput)
        if let frame = state.latestFrame { view.display(frame) }
        if let command = state.consumeCommand() { context.coordinator.perform(command) }
    }
}
#endif
