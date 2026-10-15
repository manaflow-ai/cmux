#if DEBUG
import AppKit
import CmuxCEF

/// Debug-only Chromium probe (Debug → Debug Windows → Chromium Page…): one
/// window hosting a `CEFBrowser`, so a tagged build can prove the embedded
/// engine starts, renders and quits cleanly before any browser panel uses it.
/// `CMUX_CEF_DEBUG_URL=<url>` opens it at launch. Strings are English-only by
/// design: the file is `#if DEBUG`, matching the other debug windows.
@MainActor
final class ChromiumDebugWindowController: NSObject, NSWindowDelegate {
    static let shared = ChromiumDebugWindowController()

    private var window: NSWindow?
    private var browser: CEFBrowser?
    private let status = NSTextField(labelWithString: "")

    /// Opens the window at launch when `CMUX_CEF_DEBUG_URL` is set.
    func openFromEnvironmentIfRequested(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let value = environment["CMUX_CEF_DEBUG_URL"], !value.isEmpty, let url = URL(string: value) else { return }
        show(url: url, activate: false)
    }

    func show(url: URL = URL(string: "https://example.com")!, activate: Bool = true) {
        if let window, let browser {
            browser.load(url)
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chromium Page"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.chromiumDebug")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView(frame: window.contentLayoutRect)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)

        if let reason = CEFRuntime.shared.unavailableReason {
            status.stringValue = "Chromium unavailable: \(reason.code)"
        } else {
            let browser = CEFBrowser(configuration: CEFBrowserConfiguration(profile: Self.debugProfile, initialURL: url))
            browser.onEvent = { [weak self] event in self?.handle(event) }
            let host = browser.hostView
            host.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: content.topAnchor),
                host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            ])
            self.browser = browser
            status.stringValue = "Starting Chromium…"
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        window.contentView = content
        self.window = window
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    private func handle(_ event: CEFBrowserEvent) {
        switch event {
        case .stateChanged(let state):
            let engine = "fork API \(CEFRuntime.shared.forkAPIVersion)"
            let loading = state.isLoading ? "loading" : "idle"
            status.stringValue = "\(engine) · \(loading) · \(state.url?.absoluteString ?? "") · \(state.title)"
        case .loadFailed(let code, let message, let url, _):
            status.stringValue = "load failed \(code): \(message) \(url?.absoluteString ?? "")"
        case .newBrowser(let popup, _, _, _):
            popup.close()
        case .closed:
            browser = nil
        default:
            break
        }
    }

    func windowWillClose(_ notification: Notification) {
        browser?.close()
        browser = nil
        window = nil
    }

    /// A fixed profile for the probe, apart from any real browser profile.
    private static let debugProfile = UUID(uuidString: "C0FFEE00-CEF0-4000-8000-00000000DEB6")!
}
#endif
