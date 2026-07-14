import AppKit
import CmuxVoice
import SwiftUI

/// Owns the floating dictation HUD panel.
///
/// The HUD is a non-activating floating `NSPanel` (not a pane-embedded
/// overlay) so it stays above portal-hosted terminal surfaces in every
/// window arrangement without touching the typing-latency-sensitive
/// terminal view hierarchy. It is anchored near the bottom center of the
/// key window while dictation is active and hides when the session ends.
@MainActor
final class VoiceDictationHUDController {
    private let controller: DictationController
    private var panel: NSPanel?
    private var observationActive = false

    init(controller: DictationController) {
        self.controller = controller
    }

    /// Starts tracking the controller's phase; shows/hides the panel as
    /// sessions start and end.
    func activate() {
        guard !observationActive else { return }
        observationActive = true
        observePhase()
    }

    private func observePhase() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observePhase()
            }
        }
        syncVisibility()
    }

    private func syncVisibility() {
        switch controller.phase {
        case .requestingAuthorization, .preparing, .listening, .stopping:
            show()
        case .idle, .failed:
            hide()
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(rootView: VoiceDictationHUDView(controller: controller))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        panel.contentView = effectView
        return panel
    }

    private func position(_ panel: NSPanel) {
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        guard let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - panel.frame.width / 2,
                    y: frame.minY + 120
                ))
            }
            return
        }
        let frame = anchorWindow.frame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 64
        ))
    }
}
