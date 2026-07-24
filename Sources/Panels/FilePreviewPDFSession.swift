import AppKit

@MainActor
final class FilePreviewPDFSession {
    private let viewSession = PanelOwnedNativeViewSession(
        makeView: FilePreviewPDFContainerView.init,
        closeView: { $0.close() }
    )

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> FilePreviewPDFContainerView {
        viewSession.view {
            configure(
                $0,
                panel: panel,
                revision: revision,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func update(
        _ view: FilePreviewPDFContainerView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        viewSession.update(view) {
            configure(
                $0,
                panel: panel,
                revision: revision,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func close() {
        viewSession.close()
    }

    private func configure(
        _ view: FilePreviewPDFContainerView,
        panel: FilePreviewPanel,
        revision: Int,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        view.setBackgroundAppearance(backgroundColor: backgroundColor, drawsBackground: drawsBackground)
        view.setPanel(panel)
        view.setURL(panel.fileURL, revision: revision)
    }
}
