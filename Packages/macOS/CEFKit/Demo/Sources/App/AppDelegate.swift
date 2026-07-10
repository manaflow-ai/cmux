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
    private var devToolsWindow: CEFDevToolsWindow?
    private var openBrowserCount = 0
    private var terminating = false

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
        if let extensionsRoot = Bundle.main.resourceURL?.appendingPathComponent("Extensions"),
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if browsers.isEmpty {
            CEFApp.shared.shutdown()
            return .terminateNow
        }
        // Ask CEF to destroy every browser first; terminate once
        // browserDidClose has fired for all of them, then shut CEF down.
        terminating = true
        dockedDevTools?.close(force: true)
        devToolsWindow?.close()
        for browser in browsers.values {
            browser.close(force: true)
        }
        return .terminateLater
    }

    // MARK: Browsers and profiles

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

        let url = "\(homeURL)/?profile=\(name.lowercased())"
        CEFBrowser.create(
            in: container,
            frame: container.bounds,
            url: url,
            profile: profile(for: name),
            delegate: self
        ) { [weak self] browser in
            guard let self else { return }
            self.pendingProfiles.remove(name)
            guard let browser else { return }
            self.browsers[name] = browser
            self.openBrowserCount += 1
            if self.terminating {
                browser.close(force: true)
            } else if name == self.activeProfileName {
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
            guard CEFDevTools.isDockingAvailable else {
                NSSound.beep()
                sender.selectItem(at: 0)
                return
            }
            closeAllDevTools()
            setDevToolsPaneVisible(true)
            CEFDevTools.openDocked(for: browser, in: devToolsContainer, delegate: self) { [weak self] devtools in
                guard let self else { return }
                self.dockedDevTools = devtools
                if devtools != nil { self.openBrowserCount += 1 }
            }
        case 2:  // Window: app-owned NSWindow hosting the DevTools frontend.
            guard CEFDevTools.isDockingAvailable else {
                NSSound.beep()
                sender.selectItem(at: 0)
                return
            }
            closeAllDevTools()
            CEFDevToolsWindow.open(for: browser) { [weak self] devToolsWindow in
                guard let self else { return }
                self.devToolsWindow = devToolsWindow
                guard let devToolsWindow else { return }
                self.openBrowserCount += 1
                devToolsWindow.onClose = { [weak self] in
                    self?.devToolsBrowserClosed()
                }
            }
        default:  // Off
            closeAllDevTools()
        }
    }

    private func closeAllDevTools() {
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
        devToolsContainer.isHidden = true

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(profilesHost)
        splitView.addArrangedSubview(devToolsContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

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

    func browserDidClose(_ browser: CEFBrowser) {
        devToolsBrowserClosed()
    }
}

extension AppDelegate {
    fileprivate func devToolsBrowserClosed() {
        openBrowserCount -= 1
        if terminating && openBrowserCount <= 0 {
            CEFApp.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
}
