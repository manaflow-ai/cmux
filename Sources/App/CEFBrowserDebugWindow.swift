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
        guard shouldInitializeCEF() else { return }
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

    /// Unit-test hosts skip CEF initialization because XCTest exits the
    /// injected app directly instead of using AppKit's termination path.
    /// Dedicated CEF integration tests may opt in explicitly.
    static func shouldInitializeCEF(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !isRunningUnderXCTest(environment: environment)
            || environment["CMUX_CEF_ALLOW_XCTEST_RUNTIME"] == "1"
    }

    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    /// Hook for AppDelegate.applicationShouldTerminate: terminating with CEF
    /// initialized crashes in Chromium's atexit handlers, and browser closes
    /// cannot complete while a termination is pending. Returns true when
    /// terminating may proceed; false when the caller must return
    /// .terminateCancel (termination is re-initiated automatically once CEF
    /// has shut down).
    static func prepareForApplicationTermination() -> Bool {
        CEFApp.shared.prepareForTermination {
            NSApp.terminate(nil)
        }
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
        window.title = String(
            localized: "cef.debugWindow.title",
            defaultValue: "Chromium Browser (CEF)"
        )
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
            alert.messageText = String(
                localized: "cef.debugWindow.runtimeMissing.title",
                defaultValue: "CEF runtime is not bundled in this build"
            )
            alert.informativeText = String(
                localized: "cef.debugWindow.runtimeMissing.message",
                defaultValue: """
                Fetch the CEF distribution and rebuild:
                  Packages/macOS/CEFKit/scripts/fetch-cef.sh
                  ./scripts/reload.sh --tag <tag>
                The dev build phase bundles CEF automatically when the \
                distribution is present.
                """
            )
            alert.runModal()
            return
        }
        do {
            try CEFRuntimeSupport.startIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "cef.debugWindow.initFailed.title",
                defaultValue: "CEF failed to initialize"
            )
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
    /// Stable profile identifiers (dictionary keys and cache-directory
    /// inputs); the picker shows localized display titles, so selection is
    /// resolved by index, never by title.
    private let profileNames = ["Default", "Work", "Personal"]

    private static func localizedProfileTitle(_ name: String) -> String {
        switch name {
        case "Default":
            return String(localized: "cef.debugWindow.profile.default", defaultValue: "Default")
        case "Work":
            return String(localized: "cef.debugWindow.profile.work", defaultValue: "Work")
        case "Personal":
            return String(localized: "cef.debugWindow.profile.personal", defaultValue: "Personal")
        default:
            return name
        }
    }
    private var profiles: [String: CEFProfile] = [:]
    private var browsers: [String: CEFBrowser] = [:]
    private var containers: [String: CEFBrowserContainerView] = [:]
    private var pendingProfiles: Set<String> = []
    private var activeProfileName = "Default"
    private var dockedDevTools: CEFBrowser?
    /// Bumped by closeAllDevTools; stale async open results are closed.
    private var devToolsRequestGeneration = 0
    private var devToolsWidthConstraint: NSLayoutConstraint?
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
        if let existing = profiles[name] { return existing }
        let profile = CEFProfile(name: name)
        profiles[name] = profile
        return profile
    }

    private func ensureBrowser(for name: String) {
        guard browsers[name] == nil, !pendingProfiles.contains(name) else { return }

        // A named profile must never silently fall back to the default
        // request context: that would share cookies/storage across profiles
        // the UI presents as isolated. Fail the tab instead.
        var profile: CEFProfile?
        if name != "Default" {
            guard let resolved = self.profile(for: name) else {
                NSLog("CEFBrowserDebugWindow: failed to create request context for profile %@", name)
                return
            }
            profile = resolved
        }
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
            profile: profile,
            delegate: self
        ) { [weak self] browser in
            // Creation is asynchronous: the window may have been torn down
            // (or this profile's container replaced) before it completes. An
            // unadopted browser would stay alive, hidden, for the rest of
            // the session — close it instead of orphaning it.
            guard let self, self.containers[name] === container else {
                browser?.close(force: true)
                container.removeFromSuperview()
                return
            }
            self.pendingProfiles.remove(name)
            guard let browser else {
                // Failed create: drop the orphan container so a retry does
                // not stack duplicate hosts for the same profile.
                self.containers[name] = nil
                container.removeFromSuperview()
                return
            }
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
        // NSSplitView keeps hidden arranged subviews collapsed, and holding
        // priorities preserve a freshly-added pane's zero width regardless of
        // setPosition, so the pane is added with an explicit width constraint
        // and removed entirely when undocked.
        if visible {
            if devToolsContainer.superview == nil {
                splitView.addArrangedSubview(devToolsContainer)
                let width = devToolsContainer.widthAnchor.constraint(
                    equalTo: splitView.widthAnchor, multiplier: 0.45)
                width.priority = .defaultHigh
                width.isActive = true
                devToolsWidthConstraint = width
            }
        } else if devToolsContainer.superview != nil {
            devToolsWidthConstraint?.isActive = false
            devToolsWidthConstraint = nil
            splitView.removeArrangedSubview(devToolsContainer)
            devToolsContainer.removeFromSuperview()
        }
        splitView.adjustSubviews()
    }

    private func closeAllDevTools() {
        // Invalidate in-flight open requests: target discovery and browser
        // creation are asynchronous, and a result arriving after the user
        // switched profile/Off (or the window closed) must not be adopted.
        devToolsRequestGeneration += 1
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
        let index = sender.indexOfSelectedItem
        guard profileNames.indices.contains(index) else { return }
        showProfile(profileNames[index])
    }

    @objc private func devToolsChanged(_ sender: NSPopUpButton) {
        guard let browser = activeBrowser, CEFApp.shared.isDevToolsDockingAvailable else {
            sender.selectItem(at: 0)
            return
        }
        switch sender.indexOfSelectedItem {
        case 1:
            closeAllDevTools()
            let generation = devToolsRequestGeneration
            setDevToolsPaneVisible(true)
            browser.openDockedDevTools(in: devToolsContainer) { [weak self] devtools in
                guard let self, self.devToolsRequestGeneration == generation else {
                    devtools?.close(force: true)
                    return
                }
                self.dockedDevTools = devtools
            }
        case 2:
            closeAllDevTools()
            let generation = devToolsRequestGeneration
            CEFDevToolsWindow.open(for: browser) { [weak self] devToolsWindow in
                guard let self, self.devToolsRequestGeneration == generation else {
                    devToolsWindow?.close()
                    return
                }
                self.devToolsWindow = devToolsWindow
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
        profilePicker.addItems(withTitles: profileNames.map(Self.localizedProfileTitle))
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged(_:))
        devToolsPicker.addItems(withTitles: [
            String(localized: "cef.debugWindow.devtools.off", defaultValue: "DevTools: Off"),
            String(localized: "cef.debugWindow.devtools.docked", defaultValue: "DevTools: Docked"),
            String(localized: "cef.debugWindow.devtools.window", defaultValue: "DevTools: Window"),
        ])
        devToolsPicker.target = self
        devToolsPicker.action = #selector(devToolsChanged(_:))

        [backButton, forwardButton, reloadButton, urlField, profilePicker, devToolsPicker].forEach {
            toolbar.addArrangedSubview($0)
        }

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(profilesHost)
        // devToolsContainer joins the split only while DevTools is docked.

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
        window?.title = "\(title) — \(Self.localizedProfileTitle(activeProfileName))"
    }

    func browser(_ browser: CEFBrowser, didUpdateLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard browser === activeBrowser else { return }
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }
}
