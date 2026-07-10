import AppKit
import SwiftUI

@MainActor
final class SurfacePipWindowController: NSWindowController, NSWindowDelegate {
    private let panelId: UUID
    private let onRequestReturn: (UUID) -> Void
    private var isClosingForReturn = false

    init(
        panelId: UUID,
        title: String,
        frame: NSRect,
        contentView: SurfacePipHostView,
        onRequestReturn: @escaping (UUID) -> Void
    ) {
        self.panelId = panelId
        self.onRequestReturn = onRequestReturn

        let panel = SurfacePipPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.surfacePip")
        panel.title = title
        panel.minSize = NSSize(width: 320, height: 220)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .visible
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Surface PiP intentionally floats above other apps and fullscreen
        // Spaces so a live terminal/browser can stay visible while multitasking.
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: contentView)

        super.init(window: panel)
        panel.delegate = self
        panel.onCancelOperation = { [weak self] in
            guard let self else { return }
            self.onRequestReturn(self.panelId)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func closeForReturn() {
        guard !isClosingForReturn else { return }
        isClosingForReturn = true
        window?.delegate = nil
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = sender
        guard !isClosingForReturn else { return true }
        onRequestReturn(panelId)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        guard !isClosingForReturn else { return }
        onRequestReturn(panelId)
    }
}
