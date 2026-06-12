import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Notifications popover anchor registry & anchor views
@MainActor
final class NotificationsAnchorRegistry {
    static let shared = NotificationsAnchorRegistry()

    private let anchors = NSHashTable<NSView>.weakObjects()

    private init() {}

    func register(_ view: NSView) {
        guard !anchors.contains(view) else { return }
        anchors.add(view)
    }

    func closestAnchor(in window: NSWindow, to pointInWindow: NSPoint) -> NSView? {
        anchors.allObjects
            .compactMap { view -> (view: NSView, distance: CGFloat)? in
                guard view.window === window else { return nil }
                guard notificationsPopoverAnchorIsVisible(view) else { return nil }
                let frameInWindow = view.convert(view.bounds, to: nil)
                guard !frameInWindow.isEmpty else { return nil }
                let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
                let dx = center.x - pointInWindow.x
                let dy = center.y - pointInWindow.y
                return (view, (dx * dx) + (dy * dy))
            }
            .min { $0.distance < $1.distance }?
            .view
    }
}

@MainActor
private func notificationsPopoverAnchorIsVisible(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden || candidate.alphaValue <= 0 {
            return false
        }
        current = candidate.superview
    }
    return true
}

@MainActor
func preferredNotificationsPopoverAnchor(buttonAnchor: NSView?, fallbackAnchor: NSView?) -> NSView? {
    let fallbackWindow = fallbackAnchor?.window
    guard let buttonAnchor,
          let buttonWindow = buttonAnchor.window,
          fallbackWindow == nil || buttonWindow === fallbackWindow,
          !buttonAnchor.bounds.isEmpty,
          notificationsPopoverAnchorIsVisible(buttonAnchor) else {
        return fallbackAnchor
    }
    return buttonAnchor
}

struct NotificationsAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            NotificationsAnchorRegistry.shared.register(view)
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TitlebarControlAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AnchorNSView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

