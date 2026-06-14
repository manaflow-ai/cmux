// CMUXCEFDemoApp — Path B integration smoke test.
//
// Validates that the NSView produced by `CEFEngine.makeEmbeddableBrowser`
// behaves as a regular AppKit subview when planted inside an NSSplitView.
// This is the experiment for the cmux pane integration path: instead of
// a child NSWindow per pane (which conflicts with Bonsplit's NSSplitView
// divider hit-testing), we extract CEF's underlying NSView and let
// AppKit lay it out like any other pane.
//
// Run:
//   cd CEF
//   swift build --product CMUXCEFDemoApp
//   ./Scripts/codesign_dev.sh
//   .build/.../CMUXCEFDemoApp
//
// What to watch:
//   * Three CEF browsers render content inside the NSSplitView.
//   * Vertical dividers are draggable using native NSSplitView gestures.
//   * Resizing the parent NSWindow flows through autolayout, no manual
//     frame math required.

import AppKit
import CMUXCEF

// CEF Chrome runtime needs an NSApplication that responds to
// `isHandlingSendEvent` (CrAppProtocol). Promote our subclass to be the
// shared instance before any code touches NSApplication.shared.
final class CrApplication: NSApplication {
    private var handlingSendEventStorage = false
    @objc var isHandlingSendEvent: Bool {
        get { handlingSendEventStorage }
        set { handlingSendEventStorage = newValue }
    }
    @objc func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        handlingSendEventStorage = handlingSendEvent
    }
    override func sendEvent(_ event: NSEvent) {
        let was = handlingSendEventStorage
        handlingSendEventStorage = true
        super.sendEvent(event)
        handlingSendEventStorage = was
    }
}

_ = CrApplication.shared

let exitCode = CEFEngine.executeSubprocessIfNeeded()
if exitCode >= 0 {
    exit(exitCode)
}

// MARK: - Demo controller

@MainActor
final class DemoController: NSObject, NSSplitViewDelegate {
    private static let pendingExtensionFoldersDefaultsKey = "cmux.cefDemo.pendingExtensionFolders"

    private let panes: [(profile: String, url: URL)] = [
        ("default", URL(string: "https://github.com")!),
        ("default", URL(string: "https://www.youtube.com")!),
        ("default", URL(string: "https://example.com")!),
    ]

    private var parentWindow: NSWindow!
    private var splitView: NSSplitView!
    private var browsers: [CEFBrowser] = []
    private var addressField: NSTextField!
    private var pendingExtensionFolders: [URL] = Self.loadPendingExtensionFolders()
    /// Index into `browsers` / `splitView.arrangedSubviews` of the pane
    /// the user most recently clicked. Address-bar input + back / forward /
    /// reload route to this pane. Defaults to right-most.
    private var activePaneIndex: Int = 0
    private var paneContainers: [NSView] = []

    func boot() {
        // CEF init
        let support: URL
        do {
            support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        } catch {
            print("Failed to locate Application Support directory: \(error)")
            exit(2)
        }
        let root = support
            .appendingPathComponent("cmux-cef-demo", isDirectory: true)
            .appendingPathComponent("CEFRoot", isDirectory: true)

        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let frameworkDir = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true)
        let helperPath = execURL.appendingPathComponent("CMUXCEFHelper")

        do {
            try CEFEngine.shared.start(config: CEFEngineConfig(
                rootCachePath: root,
                extensionDirectories: pendingExtensionFolders,
                logSeverity: 0,
                disableSandbox: true,
                disableGPUAcceleration: true,
                userAgentProduct: "cmux-cef-demo/0",
                frameworkDirectoryPath: frameworkDir,
                browserSubprocessPath: helperPath))
        } catch {
            print("CEFEngine.start failed: \(error)")
            exit(2)
        }

        // Parent window
        parentWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1600, height: 900),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        parentWindow.title =
            "cmux-cef-demo · Path B (NSSplitView + embedded CEF NSView)"
        parentWindow.isReleasedWhenClosed = false
        parentWindow.contentView?.wantsLayer = true
        parentWindow.contentView?.layer?.backgroundColor =
            NSColor(calibratedWhite: 0.08, alpha: 1).cgColor

        // Toolbar
        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        parentWindow.contentView!.addSubview(toolbar)

        // Split view — vanilla AppKit, native dividers.
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        parentWindow.contentView!.addSubview(splitView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: parentWindow.contentView!.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: parentWindow.contentView!.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: parentWindow.contentView!.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            splitView.leadingAnchor.constraint(equalTo: parentWindow.contentView!.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: parentWindow.contentView!.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: parentWindow.contentView!.bottomAnchor),
        ])

        parentWindow.makeKeyAndOrderFront(nil)

        // Seed three panes.
        for pane in panes {
            addPane(profile: pane.profile, url: pane.url)
        }
    }

    private func makeToolbar() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        stack.addArrangedSubview(makeBtn(symbol: "chevron.left",
                                         tip: "Back",
                                         action: #selector(backAction)))
        stack.addArrangedSubview(makeBtn(symbol: "chevron.right",
                                         tip: "Forward",
                                         action: #selector(forwardAction)))
        stack.addArrangedSubview(makeBtn(symbol: "arrow.clockwise",
                                         tip: "Reload",
                                         action: #selector(reloadAction)))

        // Address bar — applies to the right-most (newest) pane.
        addressField = NSTextField()
        addressField.placeholderString = "Enter URL and press ⏎"
        addressField.stringValue = "https://github.com"
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .none
        addressField.font = .systemFont(ofSize: 13)
        addressField.target = self
        addressField.action = #selector(addressSubmit)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(addressField)
        addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        stack.addArrangedSubview(makeBtn(symbol: "puzzlepiece.extension",
                                         tip: "Manage extensions (chrome://extensions)",
                                         action: #selector(openExtensionsAction)))
        stack.addArrangedSubview(makeBtn(symbol: "folder.badge.plus",
                                         tip: "Load unpacked extension folder…",
                                         action: #selector(loadUnpackedExtensionAction)))
        stack.addArrangedSubview(makeBtn(symbol: "rectangle.split.3x1",
                                         tip: "Add pane (right)",
                                         action: #selector(addPaneAction)))
        stack.addArrangedSubview(makeBtn(symbol: "xmark.rectangle",
                                         tip: "Close right-most pane",
                                         action: #selector(removePaneAction)))
        return view
    }

    private func activeBrowser() -> CEFBrowser? {
        guard !browsers.isEmpty else { return nil }
        let idx = min(max(activePaneIndex, 0), browsers.count - 1)
        return browsers[idx]
    }

    fileprivate func setActivePane(_ container: NSView) {
        if let idx = paneContainers.firstIndex(of: container) {
            activePaneIndex = idx
            refreshActivePaneHighlight()
            if let url = browsers[idx].currentURL ?? URL(string: panes[idx % panes.count].url.absoluteString) {
                addressField.stringValue = url.absoluteString
            }
        }
    }

    private func refreshActivePaneHighlight() {
        for (i, c) in paneContainers.enumerated() {
            c.layer?.borderColor = (i == activePaneIndex)
                ? NSColor.systemBlue.cgColor
                : NSColor.clear.cgColor
            c.layer?.borderWidth = (i == activePaneIndex) ? 2 : 0
        }
    }

    @objc private func backAction() { activeBrowser()?.goBack() }
    @objc private func forwardAction() { activeBrowser()?.goForward() }
    @objc private func reloadAction() { activeBrowser()?.reload() }

    @objc private func addressSubmit() {
        let raw = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let url: URL?
        if let direct = URL(string: raw), direct.scheme != nil {
            url = direct
        } else if raw.contains(".") && !raw.contains(" ") {
            url = URL(string: "https://\(raw)")
        } else {
            var c = URLComponents()
            c.scheme = "https"; c.host = "www.google.com"; c.path = "/search"
            c.queryItems = [URLQueryItem(name: "q", value: raw)]
            url = c.url
        }
        guard let target = url, let browser = activeBrowser() else { return }
        addressField.stringValue = target.absoluteString
        browser.load(target)
    }

    @objc private func openExtensionsAction() {
        guard let url = URL(string: "chrome://extensions") else { return }
        addressField.stringValue = url.absoluteString
        activeBrowser()?.load(url)
    }

    @objc private func loadUnpackedExtensionAction() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load Extension"
        panel.message =
            "Pick the unpacked extension folder (containing manifest.json). " +
            "Note: CEF binds the extension list at engine start, so the " +
            "selected path is appended and the message loop is restarted."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        pendingExtensionFolders.append(folder)
        savePendingExtensionFolders()
        let alert = NSAlert()
        alert.messageText = "Extension queued"
        alert.informativeText =
            "Will load the next time the demo starts:\n\(folder.path)\n\n" +
            "Restart the demo, then open chrome://extensions to inspect loaded extensions."
        alert.runModal()
        if let url = URL(string: "chrome://extensions") {
            activeBrowser()?.load(url)
        }
    }

    private static func loadPendingExtensionFolders() -> [URL] {
        UserDefaults.standard
            .stringArray(forKey: pendingExtensionFoldersDefaultsKey)?
            .map { URL(fileURLWithPath: $0) } ?? []
    }

    private func savePendingExtensionFolders() {
        UserDefaults.standard.set(
            pendingExtensionFolders.map(\.path),
            forKey: Self.pendingExtensionFoldersDefaultsKey
        )
    }

    private func makeBtn(symbol: String, tip: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .accessoryBarAction
        btn.isBordered = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            btn.image = img
            btn.imagePosition = .imageOnly
            btn.contentTintColor = .white
        } else {
            btn.title = symbol
        }
        btn.toolTip = tip
        btn.target = self
        btn.action = action
        btn.widthAnchor.constraint(equalToConstant: 32).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return btn
    }

    @objc private func addPaneAction() {
        let next = panes[browsers.count % panes.count]
        addPane(profile: next.profile, url: next.url)
    }

    @objc private func removePaneAction() {
        guard let last = browsers.popLast() else { return }
        let paneView = last.embeddableView?.superview ?? paneContainers.last ?? splitView.arrangedSubviews.last
        if let paneView {
            splitView.removeArrangedSubview(paneView)
            paneView.removeFromSuperview()
        }
        last.close()
        if !paneContainers.isEmpty { paneContainers.removeLast() }
        activePaneIndex = max(0, browsers.count - 1)
        splitView.adjustSubviews()
        refreshActivePaneHighlight()
    }

    private func addPane(profile: String, url: URL) {
        do {
            let prof = CEFProfileRegistry.shared.profile(named: profile)
            let browser = try CEFEngine.shared.makeEmbeddableBrowser(
                profile: prof, initialURL: url)
            guard let inner = browser.embeddableView else {
                FileHandle.standardError.write(
                    "makeEmbeddableBrowser returned no NSView\n".data(using:.utf8)!)
                return
            }

            let container = PaneContainerView()
            container.controller = self
            container.browser = browser
            container.wantsLayer = true
            container.layer?.backgroundColor =
                NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
            container.translatesAutoresizingMaskIntoConstraints = false

            inner.removeFromSuperview()
            inner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                inner.topAnchor.constraint(equalTo: container.topAnchor),
                inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            splitView.addArrangedSubview(container)
            paneContainers.append(container)
            redistributePanesEqually()
            browsers.append(browser)
            activePaneIndex = browsers.count - 1
            refreshActivePaneHighlight()

            FileHandle.standardError.write(
                "added pane: profile=\(profile) url=\(url)\n".data(using:.utf8)!)
        } catch {
            FileHandle.standardError.write(
                "addPane failed: \(error)\n".data(using:.utf8)!)
        }
    }

    private func redistributePanesEqually() {
        let n = splitView.arrangedSubviews.count
        guard n > 1 else { return }
        splitView.layoutSubtreeIfNeeded()
        let totalWidth = splitView.bounds.width
        let dividerThickness = splitView.dividerThickness
        let usableWidth = totalWidth - dividerThickness * CGFloat(n - 1)
        let paneWidth = usableWidth / CGFloat(n)
        // Set divider positions left-to-right.
        for i in 0 ..< (n - 1) {
            let position = paneWidth * CGFloat(i + 1) + dividerThickness * CGFloat(i)
            splitView.setPosition(position, ofDividerAt: i)
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedMin + 200
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        return proposedMax - 200
    }
}

// MARK: - Pane container

/// Container view for a single browser pane. Detects when the user
/// interacts with this pane (mouse-down event tap) and tells the
/// controller to make it the address bar's target. The CEF NSView is a
/// subview and still receives the click — we just observe it via the
/// event-monitor pattern (no event swallowing).
private final class PaneContainerView: NSView {
    weak var controller: DemoController?
    weak var browser: CEFBrowser?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let window = self.window {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self, weak window] event in
                guard let self, let window, event.window == window else { return event }
                let pointInWindow = event.locationInWindow
                let pointInSelf = self.convert(pointInWindow, from: nil)
                if self.bounds.contains(pointInSelf) {
                    self.controller?.setActivePane(self)
                }
                return event
            }
            // Keep the CEF compositor's hit-test coordinate space in
            // sync with the on-screen rect of this container.
            postsFrameChangedNotifications = true
            let frameObs = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: self, queue: .main
            ) { [weak self] _ in self?.syncCEFCoordinates() }
            observers.append(frameObs)
            let winMoveObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncCEFCoordinates() }
            observers.append(winMoveObs)
            let winResizeObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.syncCEFCoordinates() }
            observers.append(winResizeObs)
            syncCEFCoordinates()
        } else if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func syncCEFCoordinates() {
        guard let browser = self.browser, let window = self.window else { return }
        let inWin = convert(bounds, to: nil)
        let onScreen = window.convertToScreen(inWin)
        browser.syncRenderFrame(toScreen: onScreen)
    }
}

// MARK: - App boot

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let controller = DemoController()
MainActor.assumeIsolated { controller.boot() }

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            CEFEngine.shared.shutdown()
        }
    }
}
let delegate = AppDelegate()
app.delegate = delegate

let appMenuItem = NSMenuItem()
appMenuItem.submenu = NSMenu()
appMenuItem.submenu?.addItem(NSMenuItem(
    title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
let menubar = NSMenu()
menubar.addItem(appMenuItem)
app.mainMenu = menubar

MainActor.assumeIsolated {
    app.run()
    CEFEngine.shared.shutdown()
}
