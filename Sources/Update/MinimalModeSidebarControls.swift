import AppKit
import SwiftUI

enum TitlebarControlsHitRegions {
    static let outerLeadingPadding: CGFloat = 4
    static let buttonCount = 3

    static func buttonXRanges(config: TitlebarControlsStyleConfig) -> [ClosedRange<CGFloat>] {
        var ranges: [ClosedRange<CGFloat>] = []
        ranges.reserveCapacity(buttonCount)

        var minX = outerLeadingPadding + config.groupPadding.leading
        for _ in 0..<buttonCount {
            let maxX = minX + config.buttonSize
            ranges.append(minX...maxX)
            minX = maxX + config.spacing
        }

        return ranges
    }

    static func sidebarActionSlot(
        at point: NSPoint,
        config: TitlebarControlsStyleConfig
    ) -> MinimalModeSidebarControlActionSlot? {
        for (index, range) in buttonXRanges(config: config).enumerated() where range.contains(point.x) {
            return MinimalModeSidebarControlActionSlot(rawValue: index)
        }
        return nil
    }

    static func pointFallsInButtonColumn(_ point: NSPoint, config: TitlebarControlsStyleConfig) -> Bool {
        sidebarActionSlot(at: point, config: config) != nil
    }
}

struct MinimalModeSidebarControlClickProxyView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig
    let onAction: (MinimalModeSidebarControlActionSlot, NSView) -> Void

    func makeNSView(context: Context) -> ClickProxyView {
        let view = ClickProxyView()
        view.config = config
        view.onAction = onAction
        return view
    }

    func updateNSView(_ nsView: ClickProxyView, context: Context) {
        nsView.config = config
        nsView.onAction = onAction
    }

    final class ClickProxyView: NSView {
        var config = TitlebarControlsStyle.classic.config
        var onAction: ((MinimalModeSidebarControlActionSlot, NSView) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            guard bounds.contains(point) else { return nil }
            guard TitlebarControlsHitRegions.sidebarActionSlot(at: point, config: config) != nil else {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            guard let slot = TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config) else {
                super.mouseDown(with: event)
                return
            }

            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
                _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    payload["minimalSidebarClickProxyLastAction"] = slot.debugName
                    payload["minimalSidebarClickProxyLastPoint"] = windowDragHandleFormatPoint(localPoint)
                    payload["minimalSidebarClickProxyWindowNumber"] = window.map { String($0.windowNumber) } ?? "nil"
                }
            }
            #endif

            if let window {
                MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
            }
            onAction?(slot, self)
        }
    }
}
