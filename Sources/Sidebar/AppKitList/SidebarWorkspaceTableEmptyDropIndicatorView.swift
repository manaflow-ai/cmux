import AppKit
import CmuxSettings
import SwiftUI

/// AppKit counterpart of the existing two-point accent drop indicator.
@MainActor
final class SidebarWorkspaceTableEmptyDropIndicatorView: NSView {
    private var chromePalette = ChromePaletteRuntimeResolver(runtime: nil).resolve()
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

    func setChromePalette(_ palette: ChromePalette) {
        guard chromePalette != palette else { return }
        chromePalette = palette
        updateAccentColor()
    }

    private func updateAccentColor() {
        layer?.backgroundColor = chromePalette.cmuxAccentNSColor.cgColor
    }
}
