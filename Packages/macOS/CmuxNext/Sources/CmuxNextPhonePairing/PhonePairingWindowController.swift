public import AppKit
import CmuxNextDesign
import SwiftUI

/// The "Pair iPhone" window: a fixed-size tool window drawing its own glass
/// panel, with only a close button.
public final class PhonePairingWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 700, height: 440)
    static let panelInset: CGFloat = 12
    static let panelRadius: CGFloat = 20

    public let model: PhonePairingModel
    /// Called once when the window has closed.
    public var onClose: (() -> Void)?

    public init(model: PhonePairingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = PhonePairingStrings.windowTitle
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .alertPanel
        window.contentMinSize = Self.size
        window.contentMaxSize = Self.size
        window.identifier = NSUserInterfaceItemIdentifier("cmux.phonePairing")
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingView(rootView: PhonePairingView(model: model))
        window.install(kind: .onboarding, content: Self.surface(around: hosting), scope: .app)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Glass panel inset from the clear window, or an opaque fill when the
    /// user reduces transparency.
    private static func surface(around content: NSView) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        let panel: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let fill = NSView()
            fill.wantsLayer = true
            fill.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            fill.layer?.cornerRadius = panelRadius
            fill.layer?.cornerCurve = .continuous
            panel = fill
        } else {
            let fill = NSView()
            fill.wantsLayer = true
            fill.layer?.cornerRadius = panelRadius
            fill.layer?.cornerCurve = .continuous
            fill.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
            panel = Glass.makePanel(content: fill, cornerRadius: panelRadius)
        }
        for view in [panel, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: panelInset),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -panelInset),
                view.topAnchor.constraint(equalTo: root.topAnchor, constant: panelInset),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -panelInset),
            ])
        }
        return root
    }

    /// Shows the window (placement and no-activate rules: `WindowPlacement`).
    public func present() {
        guard let window else { return }
        WindowPlacement.present(window)
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
