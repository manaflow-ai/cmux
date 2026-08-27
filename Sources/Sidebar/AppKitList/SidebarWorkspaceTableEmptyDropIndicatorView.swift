import AppKit
import SwiftUI

/// AppKit counterpart of the existing two-point accent drop indicator.
@MainActor
final class SidebarWorkspaceTableEmptyDropIndicatorView: NSView {
    var colorScheme: ColorScheme = .light {
        didSet {
            guard colorScheme != oldValue else { return }
            updateAccentColor()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 1
        updateAccentColor()
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateAccentColor() {
        layer?.backgroundColor = cmuxAccentNSColor(for: colorScheme).cgColor
    }
}
