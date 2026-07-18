import AppKit
import CEFKit

/// Demo shell: one window, a toolbar with navigation controls, a profile
/// picker, and a DevTools mode picker. One embedded CEF browser per profile.
/// Proves the CEFKit claims: Chromium renders in an NSView, Chrome extensions
/// load, profiles have isolated storage, and DevTools works docked or in its
/// own window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var urlField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var profilePicker: NSPopUpButton!
    private var devToolsPicker: NSPopUpButton!
    private var splitView: NSSplitView!
    private var profilesHost: NSView!
    private var devToolsContainer: CEFBrowserContainerView!

    private let profileNames = ["Default", "Work", "Personal"]
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

    private let homeURL = "https://example.com"

    private func debugLog(_ message: String) {
        FileHandle.standardError.write(Data("CEFDemo: \(message)\n".utf8))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("didFinishLaunching")
        buildMenu()
        buildWindow()

        let fm = FileManager.default
        let rootCache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CEFDemo", isDirectory: true)

        var config = CEFConfiguration(rootCachePath: rootCache)
        config.remoteDebuggingPort = Int(ProcessInfo.processInfo.environment["CEFDEMO_DEBUG_PORT"] ?? "") ?? 0
        config.logFile = rootCache.appendingPathComponent("cef.log")
        if ProcessInfo.processInfo.environment["CEFDEMO_NO_EXTENSIONS"] != "1",
           let extensionsRoot = Bundle.main.resourceURL?.appendingPathComponent("Extensions"),
           let entries = try? fm.contentsOfDirectory(at: extensionsRoot, includingPropertiesForKeys: nil) {
            config.extensionDirectories = entries.filter { url in
                fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
            }
        }

        do {
            debugLog("initializing CEF (port \(config.remoteDebuggingPort))")
            try CEFApp.shared.initialize(config)
            debugLog("cef_initialize returned")
        } catch {
            debugLog("CEF init failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "CEF failed to initialize"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        CEFApp.shared.onContextInitialized { [weak self] in
            guard let self else { return }
            self.debugLog("CEF context initialized")
            self.showProfile(self.activeProfileName)
            if ProcessInfo.processInfo.environment["CEFDEMO_AUTOTEST"] == "1" {
                // Bring up every profile so CDP-based checks can talk to all
                // of them without UI interaction.
                for name in self.profileNames {
                    self.ensureBrowser(for: name)
                }
            }
            if ProcessInfo.processInfo.environment["CEFDEMO_STRESS"] == "1" {
                self.startStressLoop()
            }
            // Chrome-style window check (chrome://extensions etc. only work
            // there, not in Alloy-style embedded browsers).
            if let chromeURL = ProcessInfo.processInfo.environment["CEFDEMO_CHROME_WINDOW_URL"] {
                CEFBrowser.openChromeStyleWindow(url: chromeURL) { browser in
                    self.debugLog("chrome-style window: \(browser != nil ? "created" : "FAILED") for \(chromeURL)")
                }
            }
            // Popover-hosted browser check (extension-popup UX spike): can a
            // CEF browser render inside an NSPopover's window?
            if let popoverURL = ProcessInfo.processInfo.environment["CEFDEMO_POPOVER_URL"] {
                self.showSpikePopover(url: popoverURL)
            }
        }
    }

    // MARK: Popover spike (CEFDEMO_POPOVER_URL)

    private var spikePopover: NSPopover?
    private var spikePopoverBrowser: CEFBrowser?

    private func showSpikePopover(url: String) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let controller = NSViewController()
        let container = CEFBrowserContainerView(frame: NSRect(x: 0, y: 0, width: 380, height: 560))
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 560)
        spikePopover = popover
        guard let anchor = window.contentView else { return }
        popover.show(
            relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.maxY - 8, width: 10, height: 8),
            of: anchor,
            preferredEdge: .minY
        )
        CEFBrowser.create(in: container, frame: container.bounds, url: url) { [weak self] browser in
            self?.spikePopoverBrowser = browser
            self?.debugLog("popover browser: \(browser != nil ? "created" : "FAILED") for \(url)")
        }
    }

    // MARK: Stress mode (CEFDEMO_STRESS=1)

    // Exercises the host-side churn that CDP cannot drive: continuous window
    // resizing, profile (view show/hide) switching, and DevTools
    // docked/undocked/off cycling, all while CDP-side navigation and input
    // stress runs. Complements Demo/scripts/stress.mjs.
    private var stressTimer: Timer?
    private var stressTick = 0

    private func startStressLoop() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.stressStep()
        }
        RunLoop.main.add(timer, forMode: .common)
        stressTimer = timer
    }

    private func stressStep() {
        stressTick += 1
        // Comma-separated subset of resize,profiles,devtools; default all.
        let mode = ProcessInfo.processInfo.environment["CEFDEMO_STRESS_MODE"] ?? "all"
        let all = mode == "all"

        if all || mode.contains("resize") {
            // Window resize jiggle on every tick.
            var frame = window.frame
            let phase = Double(stressTick % 20) / 20.0
            frame.size.width = 900 + 350 * abs(sin(phase * .pi * 2))
            frame.size.height = 600 + 250 * abs(cos(phase * .pi * 2))
            window.setFrame(frame, display: true)
        }
        if (all || mode.contains("profiles")) && stressTick % 8 == 0 {
            let next = profileNames[(stressTick / 8) % profileNames.count]
            profilePicker.selectItem(withTitle: next)
            showProfile(next)
        }
        if mode.contains("close") && stressTick % 24 == 0 {
            // Close and recreate a profile browser (no DevTools involved) to
            // isolate browser-teardown-under-churn crashes.
            if let browser = browsers["Work"] {
                browsers.removeValue(forKey: "Work")
                containers["Work"]?.removeFromSuperview()
                containers.removeValue(forKey: "Work")
                browser.close(force: true)
            } else {
                ensureBrowser(for: "Work")
            }
        }
        if mode.contains("dockhold") {
            // Open docked DevTools once and keep it attached (state stress,
            // no close transition).
            if stressTick == 20 {
                devToolsPicker.selectItem(at: 1)
                devToolsChanged(devToolsPicker)
            }
        } else if (all || mode.contains("devtools")) && stressTick % 20 == 0 {
            // "dockonly" cycles Off/Docked; otherwise Off/Docked/Window.
            let states = mode.contains("dockonly") ? 2 : 3
            let devToolsMode = (stressTick / 20) % states
            devToolsPicker.selectItem(at: devToolsMode)
            devToolsChanged(devToolsPicker)
        }
    }

    // No applicationWillTerminate needed: Chromium's DCHECKing atexit
    // handlers are skipped by the _exit handler CEFKit registers at
    // initialize (it runs inside exit(), after all willTerminate
    // observers).

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cancel-close-reterminate: browser closes cannot complete while a
        // termination is pending, so cancel, let them close on the live run
        // loop, and terminate again once CEF has shut down.
        if CEFApp.shared.prepareForTermination(onReady: { NSApp.terminate(nil) }) {
            return .terminateNow
        }
        return .terminateCancel
    }

    // MARK: Browsers and profiles

    private func profile(for name: String) -> CEFProfile? {
        if let existing = profiles[name] { return existing }
        let profile = CEFProfile(name: name)
        profiles[name] = profile
        return profile
    }

    private func ensureBrowser(for name: String) {
        guard browsers[name] == nil, !pendingProfiles.contains(name) else { return }

        // A named profile must never silently fall back to the default
        // request context (cookies/storage would leak across profiles the
        // UI presents as isolated). Fail the tab instead.
        var profile: CEFProfile?
        if name != "Default" {
            guard let resolved = self.profile(for: name) else {
                NSLog("CEFDemo: failed to create request context for profile %@", name)
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

        let url = "\(homeURL)/?profile=\(name.lowercased())"
        CEFBrowser.create(
            in: container,
            frame: container.bounds,
            url: url,
            profile: profile,
            delegate: self
        ) { [weak self] browser in
            // Creation is asynchronous: the owner may be gone (or this
            // profile's container replaced) before it completes. Close an
            // unadopted browser instead of orphaning it.
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
        guard let browser = activeBrowser else {
            sender.selectItem(at: 0)
            return
        }
        switch sender.indexOfSelectedItem {
        case 1:  // Docked: DevTools frontend embedded in the split pane.
            guard CEFApp.shared.isDevToolsDockingAvailable else {
                NSSound.beep()
                sender.selectItem(at: 0)
                return
            }
            closeAllDevTools()
            let generation = devToolsRequestGeneration
            setDevToolsPaneVisible(true)
            browser.openDockedDevTools(in: devToolsContainer, delegate: self) { [weak self] devtools in
                guard let self, self.devToolsRequestGeneration == generation else {
                    devtools?.close(force: true)
                    return
                }
                self.dockedDevTools = devtools
            }
        case 2:  // Window: app-owned NSWindow hosting the DevTools frontend.
            guard CEFApp.shared.isDevToolsDockingAvailable else {
                NSSound.beep()
                sender.selectItem(at: 0)
                return
            }
            closeAllDevTools()
            let generation = devToolsRequestGeneration
            CEFDevToolsWindow.open(for: browser) { [weak self] devToolsWindow in
                guard let self, self.devToolsRequestGeneration == generation else {
                    devToolsWindow?.close()
                    return
                }
                self.devToolsWindow = devToolsWindow
            }
        default:  // Off
            closeAllDevTools()
        }
    }

    private func closeAllDevTools() {
        // Invalidate in-flight open requests: a result arriving after the
        // user switched profile/Off must not be adopted.
        devToolsRequestGeneration += 1
        dockedDevTools?.close(force: true)
        dockedDevTools = nil
        devToolsWindow?.close()
        devToolsWindow = nil
        setDevToolsPaneVisible(false)
    }

    // MARK: UI construction

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CEFDemo"
        window.center()

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: "◀", target: self, action: #selector(goBack))
        forwardButton = NSButton(title: "▶", target: self, action: #selector(goForward))
        let reloadButton = NSButton(title: "⟳", target: self, action: #selector(reloadPage))
        urlField = NSTextField(string: homeURL)
        urlField.target = self
        urlField.action = #selector(navigate)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        profilePicker = NSPopUpButton()
        profilePicker.addItems(withTitles: profileNames)
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged(_:))
        devToolsPicker = NSPopUpButton()
        devToolsPicker.addItems(withTitles: ["DevTools: Off", "DevTools: Docked", "DevTools: Window"])
        devToolsPicker.target = self
        devToolsPicker.action = #selector(devToolsChanged(_:))

        [backButton, forwardButton, reloadButton, urlField, profilePicker, devToolsPicker].forEach {
            toolbar.addArrangedSubview($0)
        }

        profilesHost = NSView()
        devToolsContainer = CEFBrowserContainerView()

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(profilesHost)
        // devToolsContainer joins the split only while DevTools is docked.

        let root = NSView()
        root.addSubview(toolbar)
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit CEFDemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: CEFBrowserDelegate {
    func browser(_ browser: CEFBrowser, didUpdateURL url: String) {
        guard browser === activeBrowser else { return }
        urlField.stringValue = url
    }

    func browser(_ browser: CEFBrowser, didUpdateTitle title: String) {
        guard browser === activeBrowser else { return }
        window.title = "\(title) — \(activeProfileName)"
    }

    func browser(_ browser: CEFBrowser, didUpdateLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard browser === activeBrowser else { return }
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    func browserDidClose(_ browser: CEFBrowser) {}
}
