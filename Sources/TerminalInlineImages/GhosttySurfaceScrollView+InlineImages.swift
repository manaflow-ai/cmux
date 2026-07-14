import AppKit
import Quartz

extension GhosttySurfaceScrollView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    @MainActor
    func installInlineImageThumbnails() {
        inlineImageOverlayView.frame = bounds
        inlineImageOverlayView.autoresizingMask = [.width, .height]
        inlineImageOverlayView.openPreview = { [weak self] url in
            self?.openInlineImagePreview(url: url)
        }
        addSubview(inlineImageOverlayView, positioned: .above, relativeTo: nil)
        inlineImageController = TerminalInlineImageController(
            hostedView: self,
            overlayView: inlineImageOverlayView
        )
        inlineImageController?.start()
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            inlineImagePreviewURL != nil
        }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self {
                panel.dataSource = nil
            }
            if panel.delegate === self {
                panel.delegate = nil
            }
            inlineImagePreviewURL = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            inlineImagePreviewURL == nil ? 0 : 1
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            inlineImagePreviewURL as NSURL?
        }
    }

    @MainActor
    private func openInlineImagePreview(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = MainActor.assumeIsolated({ QLPreviewPanel.shared() }) else {
            return
        }
        inlineImagePreviewURL = url
        window?.makeFirstResponder(surfaceView)
        panel.makeKeyAndOrderFront(self)
        panel.updateController()
        panel.reloadData()
    }

    @MainActor
    func inlineImagePreviewDidMoveToWindow() {
        guard window == nil else { return }
        inlineImagePreviewURL = nil
        guard MainActor.assumeIsolated({ QLPreviewPanel.sharedPreviewPanelExists() }),
              let panel = MainActor.assumeIsolated({ QLPreviewPanel.shared() }) else {
            return
        }
        if panel.dataSource === self {
            panel.dataSource = nil
        }
        if panel.delegate === self {
            panel.delegate = nil
        }
        panel.updateController()
    }
}
