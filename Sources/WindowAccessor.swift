import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            guard context.coordinator.lastWindow !== window else { return }
            context.coordinator.lastWindow = window
            onWindow(window)
        }
    }
}

extension WindowAccessor {
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}
