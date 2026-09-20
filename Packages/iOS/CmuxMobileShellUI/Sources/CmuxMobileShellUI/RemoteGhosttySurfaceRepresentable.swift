#if os(iOS)
import CmuxMobileTerminal
import CmuxMobileSupport
import CmuxRemoteConnections
import SwiftUI
import UIKit

/// Hosts the existing Ghostty renderer for a direct SSH session.
struct RemoteGhosttySurfaceRepresentable: UIViewRepresentable {
    let session: any MobileRemoteSSHSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> UIView {
        let runtime: GhosttyRuntime
        do { runtime = try GhosttyRuntime.shared() }
        catch {
            let fallback = UILabel()
            fallback.text = "Terminal renderer unavailable."
            fallback.numberOfLines = 0
            return fallback
        }
        let surface = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: 12,
            terminalTheme: .monokai,
            terminalConfigTheme: .monokai
        )
        context.coordinator.start(surface: surface)
        return GhosttySurfaceHostView(
            surfaceView: surface,
            keyboardFrameTracker: MobileKeyboardFrameTracker()
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
        (uiView as? GhosttySurfaceHostView)?.surfaceView.prepareForDismantle()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        private let session: any MobileRemoteSSHSession
        private var outputTask: Task<Void, Never>?
        private weak var surface: GhosttySurfaceView?

        init(session: any MobileRemoteSSHSession) { self.session = session }

        func start(surface: GhosttySurfaceView) {
            self.surface = surface
            outputTask = Task { @MainActor [weak self, weak surface] in
                guard let self else { return }
                do {
                    for try await data in session.output() {
                        surface?.processOutput(data)
                    }
                } catch {
                    // The connection owner reports lifecycle errors; the renderer
                    // simply stops consuming bytes when the session ends.
                }
            }
        }

        func stop() {
            outputTask?.cancel()
            outputTask = nil
            Task { await session.close() }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            Task { try? await session.sendInput(data) }
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {
            Task { try? await session.resize(columns: size.columns, rows: size.rows) }
        }
    }
}
#endif
