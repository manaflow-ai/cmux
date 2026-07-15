import AppKit
import SwiftUI

extension FileExplorerContainerView {
    func applyPlacementStyle(
        placement: FileExplorerPanelPlacement,
        paneBackgroundColor: NSColor?,
        paneColorScheme: ColorScheme?
    ) {
        let isPane = placement == .pane
        let resolvedBackgroundColor = isPane
            ? ((paneBackgroundColor?.usingColorSpace(.sRGB) ?? paneBackgroundColor ?? .windowBackgroundColor)
                .withAlphaComponent(1))
            : .clear
        let resolvedAppearance = isPane
            ? NSAppearance(named: (paneColorScheme ?? cmuxReadableColorScheme(for: resolvedBackgroundColor)) == .dark ? .darkAqua : .aqua)
            : nil

        appearance = resolvedAppearance
        setLayerBackground(on: self, color: resolvedBackgroundColor, drawsBackground: isPane)
        setLayerBackground(on: headerView, color: resolvedBackgroundColor, drawsBackground: isPane)
        setLayerBackground(on: searchBarView, color: resolvedBackgroundColor, drawsBackground: isPane)

        applyScrollBackground(
            scrollView,
            documentView: outlineView,
            color: resolvedBackgroundColor,
            drawsBackground: isPane
        )
        outlineView.backgroundColor = resolvedBackgroundColor

        applyScrollBackground(
            searchScrollView,
            documentView: searchResultsView,
            color: resolvedBackgroundColor,
            drawsBackground: isPane
        )
        searchResultsView.backgroundColor = resolvedBackgroundColor
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingSearchRefresh()
            searchController.cancel(clear: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func setLayerBackground(on view: NSView, color: NSColor, drawsBackground: Bool) {
        view.wantsLayer = drawsBackground
        view.layer?.backgroundColor = drawsBackground ? color.cgColor : NSColor.clear.cgColor
        view.layer?.isOpaque = drawsBackground
    }

    private func applyScrollBackground(
        _ scrollView: NSScrollView,
        documentView: NSView,
        color: NSColor,
        drawsBackground: Bool
    ) {
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = color
        scrollView.wantsLayer = drawsBackground
        scrollView.layer?.backgroundColor = drawsBackground ? color.cgColor : NSColor.clear.cgColor
        scrollView.layer?.isOpaque = drawsBackground

        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = color
        scrollView.contentView.wantsLayer = drawsBackground
        scrollView.contentView.layer?.backgroundColor = drawsBackground ? color.cgColor : NSColor.clear.cgColor
        scrollView.contentView.layer?.isOpaque = drawsBackground

        documentView.wantsLayer = drawsBackground
        documentView.layer?.backgroundColor = drawsBackground ? color.cgColor : NSColor.clear.cgColor
        documentView.layer?.isOpaque = drawsBackground
    }

}
