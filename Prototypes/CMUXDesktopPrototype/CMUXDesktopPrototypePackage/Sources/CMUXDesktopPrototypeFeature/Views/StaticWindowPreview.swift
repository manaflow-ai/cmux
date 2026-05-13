import AppKit
import SwiftUI

struct StaticWindowPreview: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> StaticWindowPreviewView {
        StaticWindowPreviewView()
    }

    func updateNSView(_ nsView: StaticWindowPreviewView, context: Context) {
        nsView.image = image
    }
}

final class StaticWindowPreviewView: NSView {
    var image: CGImage? {
        didSet {
            layer?.contents = image
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}
