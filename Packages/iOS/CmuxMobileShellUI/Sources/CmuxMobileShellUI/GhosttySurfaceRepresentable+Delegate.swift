#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI
import UIKit

extension GhosttySurfaceRepresentable.Coordinator: GhosttySurfaceViewDelegate {
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        Task { @MainActor [weak store] in
            await store?.submitTerminalRawInput(data, surfaceID: self.surfaceID)
        }
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {
        Task { @MainActor [weak store] in
            await store?.submitTerminalPasteImage(data, format: format)
        }
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        guard size.columns > 0, size.rows > 0 else { return }
        viewportReportScheduler?.submit(
            .init(id: reportID, columns: size.columns, rows: size.rows)
        )
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScroll run: MobileTerminalScrollRun) {
        store?.scrollTerminal(surfaceID: surfaceID, run: run)
    }

    func ghosttySurfaceViewDidBeginScrollInteraction(_ surfaceView: GhosttySurfaceView) {
        store?.terminalScrollInteractionDidBegin(surfaceID: surfaceID)
    }

    func ghosttySurfaceViewDidEndScrollInteraction(_ surfaceView: GhosttySurfaceView) {
        store?.terminalScrollInteractionDidEnd(surfaceID: surfaceID)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.artifactFilesEnabled,
               let snapshot = await surfaceView.visibleTextForArtifactHitTesting(),
               let path = TerminalArtifactTapHitTester().path(
                   in: snapshot.text,
                   col: col,
                   row: row,
                   columns: snapshot.columns
               ) {
                self.onArtifactPathTapped(path)
                return
            }
            await self.store?.clickTerminal(surfaceID: self.surfaceID, col: col, row: row)
        }
    }

    func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView) {
        guard let presenter = presentingController(for: surfaceView) else { return }
        let editor = UIHostingController(rootView: TerminalShortcutsSettingsView())
        presenter.present(editor, animated: true)
    }

    func ghosttySurfaceViewDidRequestComposerToggle(_ surfaceView: GhosttySurfaceView) {
        Task { @MainActor [weak store, surfaceID] in
            store?.toggleComposer(forTerminalID: surfaceID)
        }
    }

    func ghosttySurfaceViewDidRequestComposerFocus(_ surfaceView: GhosttySurfaceView) {
        Task { @MainActor [weak store, surfaceID] in
            store?.presentAndFocusComposer(forTerminalID: surfaceID)
        }
    }

    func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
        Task { @MainActor [weak self, weak store, surfaceID] in
            guard let self, self.surfaceView === surfaceView else { return }
            store?.terminalOutputNeedsReplay(surfaceID: surfaceID)
        }
    }

    @MainActor
    private func presentingController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
            responder = current.next
        }
        return view.window?.rootViewController
    }
}
#endif
