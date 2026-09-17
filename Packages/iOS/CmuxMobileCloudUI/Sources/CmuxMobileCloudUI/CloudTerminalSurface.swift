#if os(iOS)
import CMUXMobileCore
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// Mounts a ``GhosttySurfaceView`` and bridges it to a
/// ``CloudTerminalScreenModel``: link bytes go in through the model, and the
/// surface's typing and grid reports come back through the coordinator.
struct CloudTerminalSurface: UIViewRepresentable {
    let model: CloudTerminalScreenModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime.shared()
        } catch {
            let label = UILabel()
            label.numberOfLines = 0
            label.text = L10n.string("mobile.cloud.terminal.rendererFailed", defaultValue: "Terminal renderer failed to start.")
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator)
        context.coordinator.attach(view)
        model.setSurface(context.coordinator)
        return GhosttySurfaceHostView(
            surfaceView: view,
            keyboardFrameTracker: context.environment.mobileKeyboardFrameTracker
                ?? context.coordinator.fallbackKeyboardFrameTracker
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        (uiView as? GhosttySurfaceHostView)?.surfaceView.prepareForDismantle()
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate, CloudTerminalScreenModel.Surface {
        private let model: CloudTerminalScreenModel
        private weak var surfaceView: GhosttySurfaceView?
        let fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()

        init(model: CloudTerminalScreenModel) {
            self.model = model
        }

        func attach(_ view: GhosttySurfaceView) {
            surfaceView = view
        }

        func detach() {
            model.detach()
            surfaceView = nil
        }

        // MARK: CloudTerminalScreenModel.Surface

        func writeOutput(_ data: Data) {
            surfaceView?.processOutput(data)
        }

        func applyGrid(cols: Int, rows: Int) {
            surfaceView?.applyViewSize(cols: cols, rows: rows)
        }

        // MARK: GhosttySurfaceViewDelegate

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            model.sendInput(data)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            model.reportGrid(cols: size.columns, rows: size.rows)
        }
    }
}
#endif
