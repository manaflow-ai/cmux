import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Split Button Layout Debug Window
final class SplitButtonLayoutDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SplitButtonLayoutDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Split Button Layout"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.splitButtonLayoutDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SplitButtonLayoutDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SplitButtonLayoutDebugView: View {
    @AppStorage("debugFadeColorStyle") private var backdropStyle = 0

    private var options: [(Int, String)] {
        [
            (0, String(localized: "debug.splitButtonLayout.option.precompositedPane", defaultValue: "Pre-composited paneBackground")),
            (1, String(localized: "debug.splitButtonLayout.option.rawPane", defaultValue: "Raw paneBackground (opaque)")),
            (2, String(localized: "debug.splitButtonLayout.option.rawBar", defaultValue: "barBackground (tab chrome)")),
            (3, String(localized: "debug.splitButtonLayout.option.windowBackground", defaultValue: "windowBackgroundColor")),
            (4, String(localized: "debug.splitButtonLayout.option.controlBackground", defaultValue: "controlBackgroundColor")),
            (5, String(localized: "debug.splitButtonLayout.option.precompositedBar", defaultValue: "Pre-composited barBackground")),
            (6, String(localized: "debug.splitButtonLayout.option.translucentChrome", defaultValue: "Translucent chrome")),
            (7, String(localized: "debug.splitButtonLayout.option.hidden", defaultValue: "Hidden")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "debug.splitButtonLayout.title", defaultValue: "Button Backdrop Color"))
                .font(.headline)

            ForEach(options, id: \.0) { id, label in
                HStack {
                    Image(systemName: backdropStyle == id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(backdropStyle == id ? .accentColor : .secondary)
                    Text(label)
                }
                .contentShape(Rectangle())
                .onTapGesture { backdropStyle = id }
            }

            Text(String(localized: "debug.splitButtonLayout.liveNote", defaultValue: "Changes apply live."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tab Bar Backdrop Lab Window

