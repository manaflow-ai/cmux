import SwiftUI
import Foundation
import AppKit
import Bonsplit

/// View that renders the appropriate panel view based on panel type
struct PanelContentView: View {
    let panel: any Panel
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let hasUnreadNotification: Bool
    let onFocus: () -> Void
    let onHoverFocusRequest: () -> Void
    let onRequestPanelFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        Group {
            switch panel.panelType {
            case .terminal:
                if let terminalPanel = panel as? TerminalPanel {
                    TerminalPanelView(
                        panel: terminalPanel,
                        paneId: paneId,
                        isFocused: isFocused,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        isSplit: isSplit,
                        appearance: appearance,
                        hasUnreadNotification: hasUnreadNotification,
                        onFocus: onFocus,
                        onTriggerFlash: onTriggerFlash
                    )
                }
            case .browser:
                if let browserPanel = panel as? BrowserPanel {
                    BrowserPanelView(
                        panel: browserPanel,
                        paneId: paneId,
                        isFocused: isFocused,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                }
            case .markdown:
                if let markdownPanel = panel as? MarkdownPanel {
                    MarkdownPanelView(
                        panel: markdownPanel,
                        isFocused: isFocused,
                        isVisibleInUI: isVisibleInUI,
                        portalPriority: portalPriority,
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                }
            }
        }
        .overlay(PaneHoverFocusOverlay(onHoverEntered: onHoverFocusRequest))
    }
}

private struct PaneHoverFocusOverlay: NSViewRepresentable {
    let onHoverEntered: () -> Void

    func makeNSView(context: Context) -> PaneHoverFocusTrackingView {
        let view = PaneHoverFocusTrackingView()
        view.onHoverEntered = onHoverEntered
        return view
    }

    func updateNSView(_ nsView: PaneHoverFocusTrackingView, context: Context) {
        nsView.onHoverEntered = onHoverEntered
    }
}

private final class PaneHoverFocusTrackingView: NSView {
    var onHoverEntered: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverEntered?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
