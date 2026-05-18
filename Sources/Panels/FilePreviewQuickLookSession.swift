import AppKit
import Foundation
import Quartz

private final class FilePreviewQLItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? {
        url
    }

    var previewItemTitle: String? {
        title
    }
}

@MainActor
final class FilePreviewQuickLookSession {
    private let viewSession = PanelOwnedNativeViewSession<NSView>(
        makeView: FilePreviewQuickLookSession.makeView,
        closeView: { view in
            if let previewView = view as? QLPreviewView {
                previewView.close()
                previewView.previewItem = nil
            }
            view.removeFromSuperview()
        }
    )
    private var item: FilePreviewQLItem?

    deinit {
        // AppKit teardown is performed explicitly by close() on the main actor.
    }

    func view(
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) -> NSView {
        viewSession.view {
            configure(
                $0,
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func update(
        _ view: NSView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        viewSession.update(view) {
            configure(
                $0,
                panel: panel,
                isVisibleInUI: isVisibleInUI,
                backgroundColor: backgroundColor,
                drawsBackground: drawsBackground
            )
        }
    }

    func close() {
        viewSession.close()
        item = nil
    }

    private static func makeView() -> NSView {
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            return NSView()
        }
        previewView.autostarts = true
        return previewView
    }

    private func configure(
        _ view: NSView,
        panel: FilePreviewPanel,
        isVisibleInUI: Bool,
        backgroundColor: NSColor,
        drawsBackground: Bool
    ) {
        view.isHidden = !isVisibleInUI
        if let previewView = view as? QLPreviewView {
            panel.attachPreviewFocus(root: previewView, primaryResponder: previewView, intent: .quickLook)
            previewView.previewItem = previewItem(for: panel.fileURL, title: panel.displayTitle)
        }
        FilePreviewNativeBackground.applyRootLayer(
            to: view,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    private func previewItem(for url: URL, title: String) -> FilePreviewQLItem {
        if let item, item.url == url, item.title == title {
            return item
        }
        let next = FilePreviewQLItem(url: url, title: title)
        item = next
        return next
    }
}
