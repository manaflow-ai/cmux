#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI host for a decoded Mac browser frame stream and its UIKit input surface.
struct BrowserStreamSurfaceRepresentable: UIViewRepresentable {
    /// The observable panel state.
    let state: BrowserStreamSurfaceState
    /// Decoded frames for this subscription.
    let frames: AsyncStream<BrowserStreamFrame>
    /// RPC action sink.
    let actions: BrowserStreamSurfaceActions
    /// Called after the decoded image is installed into the layer.
    let didDisplay: @MainActor (BrowserStreamFrame) -> Void

    /// Creates a browser stream representable.
    init(
        state: BrowserStreamSurfaceState,
        frames: AsyncStream<BrowserStreamFrame>,
        actions: BrowserStreamSurfaceActions,
        didDisplay: @escaping @MainActor (BrowserStreamFrame) -> Void
    ) {
        self.state = state
        self.frames = frames
        self.actions = actions
        self.didDisplay = didDisplay
    }

    func makeCoordinator() -> BrowserStreamSurfaceCoordinator {
        BrowserStreamSurfaceCoordinator(
            panelID: state.id,
            frames: frames,
            actions: actions,
            didDisplay: didDisplay
        )
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
