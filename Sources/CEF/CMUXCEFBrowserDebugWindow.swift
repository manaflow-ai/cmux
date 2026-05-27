import AppKit
import SwiftUI

final class CMUXCEFBrowserDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CMUXCEFBrowserDebugWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.menu.cefBrowserDebug", defaultValue: "CEF Browser Debug...")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cefBrowserDebug")
        window.contentView = NSHostingView(rootView: CMUXCEFBrowserDebugContentView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = NSHostingView(rootView: CMUXCEFBrowserDebugContentView())
    }
}

private struct CMUXCEFBrowserDebugContentView: View {
    var body: some View {
        CMUXCEFBrowserDebugRepresentable()
            .frame(minWidth: 640, minHeight: 420)
            .ignoresSafeArea()
    }
}

private struct CMUXCEFBrowserDebugRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        guard CMUXCEFPrepareApplication(),
              CMUXCEFIsRuntimeAvailable(),
              CMUXCEFInitialize(Int32(CommandLine.argc), CommandLine.unsafeArgv) else {
            let label = NSTextField(
                wrappingLabelWithString: String(
                    localized: "debug.cefBrowserDebug.runtimeUnavailable",
                    defaultValue: "CEF runtime unavailable."
                )
            )
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            let container = NSView(frame: .zero)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -48)
            ])
            return container
        }

        return CMUXCEFBrowserView(
            frame: .zero,
            initialURL: "https://example.com"
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CMUXCEFBrowserView)?.closeBrowser()
    }
}
