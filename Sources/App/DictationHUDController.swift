import AppKit
import CmuxDictation
import SwiftUI

/// Floating non-activating HUD showing dictation state and the live partial
/// transcript over the focused window.
@MainActor
final class DictationHUDController {
    /// The panel hosting the HUD.
    private let panel: NSPanel
    /// The controller whose phase drives the content.
    private let controller: DictationController

    /// Creates the HUD for a controller. The panel is ordered out until the
    /// first non-idle phase arrives.
    init(controller: DictationController) {
        self.controller = controller
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(
            rootView: DictationHUDView(controller: controller)
        )
    }

    /// Shows the HUD centered above the key window (or screen center).
    func show() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    /// Orders the HUD out.
    func hide() {
        panel.orderOut(nil)
    }

    private func positionPanel() {
        let frame = panel.frame
        let anchor: NSRect
        if let keyWindow = NSApp.keyWindow {
            anchor = keyWindow.frame
        } else if let screen = NSScreen.main {
            anchor = screen.visibleFrame
        } else {
            anchor = NSRect(x: 0, y: 0, width: 800, height: 600)
        }
        let originX = anchor.midX - frame.width / 2
        let originY = anchor.maxY - frame.height - 72
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

/// HUD content: phase label plus the live partial transcript.
@MainActor
struct DictationHUDView: View {
    /// The observed controller; phase and partial updates re-render the view.
    let controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                if !controller.partialTranscript.isEmpty {
                    Text(controller.partialTranscript)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var statusTitle: String {
        switch controller.phase {
        case .listening:
            return String(localized: "dictation.hud.listening", defaultValue: "Listening…")
        case .stopping, .requestingPermission:
            return String(localized: "dictation.hud.finishing", defaultValue: "Finishing…")
        case .unavailable:
            return String(
                localized: "dictation.hud.unavailable",
                defaultValue: "Dictation unavailable — check Microphone and Speech Recognition permissions"
            )
        case .idle:
            return String(localized: "dictation.hud.listening", defaultValue: "Listening…")
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .listening:
            return .red
        case .stopping, .requestingPermission:
            return .orange
        case .unavailable:
            return .gray
        case .idle:
            return .gray
        }
    }
}
