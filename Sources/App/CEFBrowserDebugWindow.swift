import AppKit
import CEFKit

/// Debug window hosting a Chromium (CEF) browser inside the real cmux
/// process: address bar, per-window Chrome profile picker, and DevTools
/// docked in a split or in a separate window. Dev-build only in practice —
/// the CEF runtime is bundled by scripts/copy-cef-runtime-dev.sh when the
/// CEFKit package has a fetched CEF distribution, and this window explains
/// how to enable it otherwise.
@MainActor
enum CEFRuntimeSupport {
    private(set) static var startedThisSession = false

    static var isRuntimeBundled: Bool {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return false }
        let binary = frameworks.appendingPathComponent(
            "Chromium Embedded Framework.framework/Chromium Embedded Framework"
        )
        return FileManager.default.fileExists(atPath: binary.path)
    }

    /// Lazily initializes CEF for this process. CEF cannot be re-initialized
    /// after shutdown, so it is started at most once per app run and shut
    /// down only at process exit. The 30Hz message pump only exists after
    /// this runs, so cmux sessions that never open a CEF browser pay nothing.
    static func startIfNeeded() throws {
        guard !CEFApp.shared.isInitialized else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "cmux"
        let rootCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CEFKit", isDirectory: true)

        var config = CEFConfiguration(rootCachePath: rootCache)
        // Stable per-bundle-id CDP port (also powers docked DevTools);
        // distinct tagged dev builds get distinct ports. djb2, not hashValue:
        // Swift string hashes are seeded per process and would move the port
        // on every launch.
        var hash: UInt64 = 5381
        for byte in bundleID.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        config.remoteDebuggingPort = 12100 + Int(hash % 800)
        if let override = ProcessInfo.processInfo.environment["CMUX_CEF_DEBUG_PORT"], let port = Int(override) {
            config.remoteDebuggingPort = port
        }
        config.logFile = rootCache.appendingPathComponent("cef.log")
        config.extensionDirectories = extensionDirectories()
        try CEFApp.shared.initialize(config)
        startedThisSession = true
    }

    private static func extensionDirectories() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("CEFExtensions") {
            roots.append(bundled)
        }
        roots.append(
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/cmux/cef-extensions", isDirectory: true)
        )
        var result: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            result.append(contentsOf: entries.filter {
                fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
            })
        }
        return result
    }
}

final class CEFBrowserDebugWindowController: ReleasingWindowController {
    static let shared = CEFBrowserDebugWindowController()

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1150, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Chromium Browser (CEF)"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cefBrowserDebug")
        window.isReleasedWhenClosed = false
        window.center()
        let view = CEFBrowserDebugView()
        window.contentView = view
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        (window.contentView as? CEFBrowserDebugView)?.teardown()
    }

    func show() {
        guard CEFRuntimeSupport.isRuntimeBundled else {
            let alert = NSAlert()
            alert.messageText = "CEF runtime is not bundled in this build"
            alert.informativeText = """
            Fetch the CEF distribution and rebuild:
              Packages/macOS/CEFKit/scripts/fetch-cef.sh
              ./scripts/reload.sh --tag <tag>
            The dev build phase bundles CEF automatically when the \
            distribution is present.
            """
            alert.runModal()
            return
        }
        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = "CEF failed to initialize"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }
        showManagedWindow(activateApplication: true)
        (window?.contentView as? CEFBrowserDebugView)?.startIfNeeded()
    }
}

/// The window content: toolbar + per-profile browsers + docked DevTools pane.
final class CEFBrowserDebugView: NSView {
    private let profileNames = ["Default", "Work", "Personal"]
    private var profiles: [String: CEFProfile] = [:]
    private var browsers: [String: CEFBrowser] = [:]
    private var containers: [String: CEFBrowserContainerView] = [:]
    private var pendingProfiles: Set<String> = []
    private var activeProfileName = "Default"
    private var dockedDevTools: CEFBrowser?
    private var devToolsWindow: CEFDevToolsWindow?
    private var started = false

    private let urlField = NSTextField(string: "https://example.com")
    private let backButton = NSButton(title: "◀", target: nil, action: nil)
    private let forwardButton = NSButton(title: "▶", target: nil, action: nil)
    private let reloadButton = NSButton(title: "⟳", target: nil, action: nil)
    private let profilePicker = NSPopUpButton()
    private let devToolsPicker = NSPopUpButton()
    private let splitView = NSSplitView()
    private let profilesHost = NSView()
    private let devToolsContainer = CEFBrowserContainerView()

    init() {
        super.init(frame: .zero)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        CEFApp.shared.onContextInitialized { [weak self] in
            guard let self else { return }
            self.showProfile(self.activeProfileName)
        }
    }

    /// Closes every browser owned by this view. CEF stays initialized for
    /// the rest of the app run (reopening the window creates new browsers).
    func teardown() {
        closeAllDevTools()
        for (_, browser) in browsers {
            browser.close(force: true)
        }
        browsers.removeAll()
        containers.values.forEach { $0.removeFromSuperview() }
        containers.removeAll()
        pendingProfiles.removeAll()
        started = false
    }

    // MARK: Browsers

    private func profile(for name: String) -> CEFProfile? {
        if name == "Default" { return nil }
        if let existing = profiles[name] { return existing }
        let profile = CEFProfile(name: name)
        profiles[name] = profile
        return profile
    }

    private func ensureBrowser(for name: String) {
        guard browsers[name] == nil, !pendingProfiles.contains(name) else { return }
        pendingProfiles.insert(name)

        let container = CEFBrowserContainerView(frame: profilesHost.bounds)
        container.autoresizingMask = [.width, .height]
        container.isHidden = name != activeProfileName
        profilesHost.addSubview(container)
        containers[name] = container

        CEFBrowser.create(
            in: container,
            frame: container.bounds,
            url: urlField.stringValue,
            profile: profile(for: name),
            delegate: self
        ) { [weak self] browser in
            guard let self else { return }
            self.pendingProfiles.remove(name)
            guard let browser else { return }
            self.browsers[name] = browser
            if name == self.activeProfileName {
                self.refreshControls()
            }
        }
    }

    private func showProfile(_ name: String) {
        if activeProfileName != name {
            closeAllDevTools()
            devToolsPicker.selectItem(at: 0)
        }
        activeProfileName = name
        ensureBrowser(for: name)
        for (profileName, container) in containers {
            container.isHidden = profileName != name
        }
        refreshControls()
    }

    private var activeBrowser: CEFBrowser? {
        browsers[activeProfileName]
    }

    private func refreshControls() {
        guard let browser = activeBrowser else { return }
        backButton.isEnabled = browser.canGoBack
        forwardButton.isEnabled = browser.canGoForward
        if let url = browser.url {
            urlField.stringValue = url
        }
    }

    private func setDevToolsPaneVisible(_ visible: Bool) {
        devToolsContainer.isHidden = !visible
        if visible {
            splitView.setPosition(max(splitView.bounds.width * 0.6, 300), ofDividerAt: 0)
        }
        splitView.adjustSubviews()
    }

    private func closeAllDevTools() {
        dockedDevTools?.close(force: true)
        dockedDevTools = nil
        devToolsWindow?.close()
        devToolsWindow = nil
        setDevToolsPaneVisible(false)
    }

    // MARK: Actions

    @objc private func goBack() { activeBrowser?.goBack() }
    @objc private func goForward() { activeBrowser?.goForward() }
    @objc private func reloadPage() { activeBrowser?.reload() }

    @objc private func navigate() {
        var text = urlField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") && !text.hasPrefix("chrome:") {
            text = "https://\(text)"
        }
        activeBrowser?.load(url: text)
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        showProfile(name)
    }

    @objc private func devToolsChanged(_ sender: NSPopUpButton) {
        guard let browser = activeBrowser, CEFDevTools.isDockingAvailable else {
            sender.selectItem(at: 0)
            return
        }
        switch sender.indexOfSelectedItem {
        case 1:
            closeAllDevTools()
            setDevToolsPaneVisible(true)
            CEFDevTools.openDocked(for: browser, in: devToolsContainer) { [weak self] devtools in
                self?.dockedDevTools = devtools
            }
        case 2:
            closeAllDevTools()
            CEFDevToolsWindow.open(for: browser) { [weak self] devToolsWindow in
                self?.devToolsWindow = devToolsWindow
            }
        default:
            closeAllDevTools()
        }
    }

    // MARK: UI

    private func buildUI() {
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        urlField.target = self
        urlField.action = #selector(navigate)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        profilePicker.addItems(withTitles: profileNames)
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged(_:))
        devToolsPicker.addItems(withTitles: ["DevTools: Off", "DevTools: Docked", "DevTools: Window"])
        devToolsPicker.target = self
        devToolsPicker.action = #selector(devToolsChanged(_:))

        [backButton, forwardButton, reloadButton, urlField, profilePicker, devToolsPicker].forEach {
            toolbar.addArrangedSubview($0)
        }

        devToolsContainer.isHidden = true
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(profilesHost)
        splitView.addArrangedSubview(devToolsContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        addSubview(toolbar)
        addSubview(splitView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

extension CEFBrowserDebugView: CEFBrowserDelegate {
    func browser(_ browser: CEFBrowser, didUpdateURL url: String) {
        guard browser === activeBrowser else { return }
        urlField.stringValue = url
    }

    func browser(_ browser: CEFBrowser, didUpdateTitle title: String) {
        guard browser === activeBrowser else { return }
        window?.title = "\(title) — \(activeProfileName)"
    }

    func browser(_ browser: CEFBrowser, didUpdateLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard browser === activeBrowser else { return }
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }
}
