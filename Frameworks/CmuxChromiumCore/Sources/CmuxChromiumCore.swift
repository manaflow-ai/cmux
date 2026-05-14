import AppKit
import Darwin
import Foundation
import OSLog
import QuartzCore

private let cmuxChromiumLogger = Logger(subsystem: "com.cmuxterm.app", category: "chromium-core")

@objc(CmuxChromiumBrowserHostFactory)
public final class CmuxChromiumBrowserHostFactory: NSObject {
    @objc(cmuxCreateBrowserHostWithProfileIdentifier:dataDirectory:proxyConfiguration:)
    public static func cmuxCreateBrowserHost(
        profileIdentifier: String,
        dataDirectory: NSURL,
        proxyConfiguration: NSDictionary?
    ) -> NSObject? {
        CmuxChromiumBrowserHost(
            profileIdentifier: profileIdentifier,
            dataDirectory: dataDirectory as URL,
            proxyConfiguration: proxyConfiguration
        )
    }
}

@objc(CmuxChromiumBrowserHost)
public final class CmuxChromiumBrowserHost: NSObject {
    private let view: CmuxChromiumBrowserView

    @objc public var cmuxNativeView: NSView? { view }
    @objc public var cmuxCurrentURL: NSURL? { view.currentURL as NSURL? }
    @objc public var cmuxTitle: String? { view.currentTitle }
    @objc public var cmuxIsLoading: Bool { view.isLoading }
    @objc public var cmuxCanGoBack: Bool { view.canGoBack }
    @objc public var cmuxCanGoForward: Bool { view.canGoForward }
    @objc public var cmuxEstimatedProgress: Double { view.estimatedProgress }
    @objc public var cmuxPageZoomFactor: NSNumber { NSNumber(value: view.pageZoomFactor) }

    init(profileIdentifier: String, dataDirectory: URL, proxyConfiguration: NSDictionary?) {
        view = CmuxChromiumBrowserView(
            profileIdentifier: profileIdentifier,
            dataDirectory: dataDirectory,
            proxyConfiguration: proxyConfiguration
        )
        super.init()
    }

    @objc(cmuxLoad:)
    public func cmuxLoad(_ request: NSURLRequest) {
        guard let url = request.url else { return }
        view.load(url)
    }

    @objc(cmuxReload)
    public func cmuxReload() {
        view.reload()
    }

    @objc(cmuxStopLoading)
    public func cmuxStopLoading() {
        view.stopLoading()
    }

    @objc(cmuxGoBack)
    public func cmuxGoBack() {
        view.goBack()
    }

    @objc(cmuxGoForward)
    public func cmuxGoForward() {
        view.goForward()
    }

    @objc(cmuxSetStateChangedHandler:)
    public func cmuxSetStateChangedHandler(_ handler: @escaping () -> Void) {
        view.stateChangedHandler = handler
    }

    @objc(cmuxEvaluateJavaScript:completionHandler:)
    public func cmuxEvaluateJavaScript(
        _ script: String,
        completionHandler: @escaping (Any?, String?) -> Void
    ) {
        view.evaluateJavaScript(script, completion: completionHandler)
    }

    @objc(cmuxTakeSnapshot:)
    public func cmuxTakeSnapshot(_ completion: @escaping (NSImage?) -> Void) {
        view.takeSnapshot(completion)
    }

    @objc(cmuxSetProxyConfiguration:)
    public func cmuxSetProxyConfiguration(_ proxyConfiguration: NSDictionary?) {
        view.setProxyConfiguration(proxyConfiguration)
    }

    @objc(cmuxSetAppearanceName:)
    public func cmuxSetAppearanceName(_ appearanceName: NSString?) {
        view.setAppearanceName(appearanceName as String?)
    }

    @objc(cmuxSetPageZoomFactor:)
    public func cmuxSetPageZoomFactor(_ pageZoomFactor: NSNumber) {
        view.setPageZoomFactor(pageZoomFactor.doubleValue)
    }

    @objc(cmuxAddUserScript:)
    public func cmuxAddUserScript(_ source: NSString) {
        view.addUserScript(source as String)
    }

    @objc(cmuxAddUserStyle:)
    public func cmuxAddUserStyle(_ source: NSString) {
        view.addUserStyle(source as String)
    }
}

final class CmuxChromiumBrowserView: NSView {
    private let profileIdentifier: String
    private let dataDirectory: URL
    private let sessionDirectory: URL
    private let contextFile: URL
    private let resizeFile: URL
    private let controlSocketFile: URL
    private let controlChannel: OwlControlChannel
    private let freshMojoRuntime: OwlFreshMojoRuntime?
    private var freshMojoSession: OpaquePointer?
    private var freshMojoUserDataPointer: UnsafeMutableRawPointer?
    private var freshMojoPollTimer: Timer?
    private var process: Process?
    private var ioPipe: Pipe?
    private var pollTimer: Timer?
    private var hostLayer: CALayer?
    private var currentContextID: UInt32 = 0
    private var lastResizeSize: NSSize = .zero
    private var pendingURL: URL?
    private var launchedURL: URL?
    private var contentShellPID: pid_t = 0
    private var devToolsPort: Int?
    private var devToolsPageWebSocketURL: URL?
    private let devToolsQueue = DispatchQueue(label: "cmux.chromium.devtools")
    private static let sharedFreshMojoRuntime = OwlFreshMojoRuntime.load()
    private var proxyServer: String?
    private var navigationHistory: [URL] = []
    private var navigationHistoryIndex: Int = -1
    private var persistentUserScripts: [String] = []
    private var persistentUserStyles: [String] = []
    private var lastPersistentStateKey: String?

    var stateChangedHandler: (() -> Void)?
    private(set) var currentURL: URL?
    private(set) var currentTitle: String?
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var pageZoomFactor = 1.0

    init(profileIdentifier: String, dataDirectory: URL, proxyConfiguration: NSDictionary?) {
        self.profileIdentifier = profileIdentifier
        self.dataDirectory = dataDirectory
        proxyServer = Self.proxyServer(from: proxyConfiguration)
        sessionDirectory = dataDirectory.appendingPathComponent("content-shell", isDirectory: true)
        let token = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        let shortToken = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        contextFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-context-\(token).txt", isDirectory: false)
        resizeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chromium-resize-\(token).txt", isDirectory: false)
        controlSocketFile = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-chr-\(shortToken).sock", isDirectory: false)
        controlChannel = OwlControlChannel(path: controlSocketFile.path)
        freshMojoRuntime = Self.sharedFreshMojoRuntime
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        teardown()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let session = freshMojoSession,
           let freshMojoRuntime {
            _ = freshMojoRuntime.setFocus(session, focused: true)
        }
        _ = controlChannel.sendFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let session = freshMojoSession,
           let freshMojoRuntime {
            _ = freshMojoRuntime.setFocus(session, focused: false)
        }
        _ = controlChannel.sendFocus(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        launchIfPossible()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer?.frame = bounds
        CATransaction.commit()
        writeResizeIfNeeded()
        launchIfPossible()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self
        ))
    }

    func load(_ url: URL) {
        pendingURL = url
        currentURL = url
        currentTitle = url.host(percentEncoded: false) ?? url.absoluteString
        lastPersistentStateKey = nil
        recordNavigation(url)
        isLoading = true
        estimatedProgress = max(estimatedProgress, 0.1)
        notifyStateChanged()

        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.navigate(session, url: url.absoluteString) {
            launchedURL = url
            return
        }

        if process != nil, launchedURL != nil, controlChannel.sendNavigate(url.absoluteString) {
            launchedURL = url
            return
        }
        if launchedURL != url {
            restartForPendingURL()
        }
        launchIfPossible()
    }

    func reload() {
        guard let url = currentURL ?? pendingURL else { return }
        pendingURL = url
        lastPersistentStateKey = nil
        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.navigate(session, url: url.absoluteString) {
            isLoading = true
            estimatedProgress = 0.1
            notifyStateChanged()
            return
        }
        if process != nil, controlChannel.sendReload() {
            isLoading = true
            estimatedProgress = 0.1
            notifyStateChanged()
            return
        }
        restartForPendingURL()
    }

    func stopLoading() {
        if let session = freshMojoSession,
           let freshMojoRuntime {
            _ = freshMojoRuntime.executeJavaScript(session, script: "window.stop()")
        }
        _ = controlChannel.sendStop()
        isLoading = false
        notifyStateChanged()
    }

    func goBack() {
        guard let targetURL = stepNavigationHistory(delta: -1) else { return }
        if let session = freshMojoSession,
           let freshMojoRuntime {
            _ = freshMojoRuntime.executeJavaScript(session, script: "history.back()")
            return
        }
        if controlChannel.sendGoBack() {
            return
        }
        pendingURL = targetURL
        restartForPendingURL()
    }

    func goForward() {
        guard let targetURL = stepNavigationHistory(delta: 1) else { return }
        if let session = freshMojoSession,
           let freshMojoRuntime {
            _ = freshMojoRuntime.executeJavaScript(session, script: "history.forward()")
            return
        }
        if controlChannel.sendGoForward() {
            return
        }
        pendingURL = targetURL
        restartForPendingURL()
    }

    func setProxyConfiguration(_ proxyConfiguration: NSDictionary?) {
        let nextProxyServer = Self.proxyServer(from: proxyConfiguration)
        guard proxyServer != nextProxyServer else { return }
        proxyServer = nextProxyServer
        guard launchedURL != nil || pendingURL != nil else { return }
        pendingURL = currentURL ?? pendingURL ?? launchedURL
        restartForPendingURL()
    }

    func setAppearanceName(_ appearanceName: String?) {
        let nextAppearance: NSAppearance?
        switch appearanceName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dark":
            nextAppearance = NSAppearance(named: .darkAqua)
        case "light":
            nextAppearance = NSAppearance(named: .aqua)
        default:
            nextAppearance = nil
        }
        appearance = nextAppearance
        hostLayer?.setNeedsDisplay()
    }

    func setPageZoomFactor(_ pageZoomFactor: Double) {
        let clamped = min(3.0, max(0.25, pageZoomFactor))
        guard abs(self.pageZoomFactor - clamped) >= 0.0001 else { return }
        self.pageZoomFactor = clamped
        lastPersistentStateKey = nil
        applyPersistentBrowserState()
    }

    func addUserScript(_ source: String) {
        persistentUserScripts.append(source)
        lastPersistentStateKey = nil
        applyPersistentBrowserState()
    }

    func addUserStyle(_ source: String) {
        persistentUserStyles.append(source)
        lastPersistentStateKey = nil
        applyPersistentBrowserState()
    }

    func evaluateJavaScript(_ script: String, completion: @escaping (Any?, String?) -> Void) {
        if let session = freshMojoSession,
           let freshMojoRuntime {
            let evaluate = {
                switch freshMojoRuntime.executeJavaScript(session, script: script) {
                case .failure(let error):
                    cmuxChromiumLogger.error("JavaScript evaluation failed: \(error.localizedDescription, privacy: .private)")
                    completion(nil, Self.browserScriptFailedTitle())
                case .success(let value):
                    completion(value, nil)
                }
            }
            if Thread.isMainThread {
                evaluate()
            } else {
                DispatchQueue.main.async(execute: evaluate)
            }
            return
        }

        devToolsQueue.async { [weak self] in
            guard let self else { return completion(nil, Self.browserScriptFailedTitle()) }
            self.ensureDevToolsPageWebSocketURL { result in
                switch result {
                case .failure(let error):
                    cmuxChromiumLogger.error("DevTools endpoint unavailable: \(error.localizedDescription, privacy: .private)")
                    completion(nil, Self.browserScriptFailedTitle())
                case .success(let url):
                    self.sendDevToolsCommand(
                        webSocketURL: url,
                        method: "Runtime.evaluate",
                        params: [
                            "expression": script,
                            "returnByValue": true,
                            "awaitPromise": true
                        ]
                    ) { commandResult in
                        switch commandResult {
                        case .failure(let error):
                            cmuxChromiumLogger.error("DevTools command failed: \(error.localizedDescription, privacy: .private)")
                            completion(nil, Self.browserScriptFailedTitle())
                        case .success(let payload):
                            if let exception = payload["exceptionDetails"] {
                                cmuxChromiumLogger.error("Page JavaScript exception: \(String(describing: exception), privacy: .private)")
                                completion(nil, Self.browserScriptFailedTitle())
                                return
                            }
                            let result = payload["result"] as? [String: Any]
                            completion(result?["value"], nil)
                        }
                    }
                }
            }
        }
    }

    private func applyPersistentBrowserState() {
        guard freshMojoSession != nil || devToolsPort != nil || currentContextID != 0 else { return }
        let key = [
            currentURL?.absoluteString ?? "",
            String(currentContextID),
            String(format: "%.4f", pageZoomFactor),
            String(persistentUserScripts.count),
            String(persistentUserStyles.count)
        ].joined(separator: "|")
        guard key != lastPersistentStateKey else { return }
        lastPersistentStateKey = key

        evaluateJavaScript(Self.pageZoomScript(for: pageZoomFactor)) { _, _ in }
        for source in persistentUserScripts {
            evaluateJavaScript(source) { _, _ in }
        }
        for source in persistentUserStyles {
            evaluateJavaScript(source) { _, _ in }
        }
    }

    private static func pageZoomScript(for factor: Double) -> String {
        let zoom = String(format: "%.4f", factor)
        return """
        (() => {
          const zoom = '\(zoom)';
          if (document.documentElement) {
            document.documentElement.style.zoom = zoom;
          }
          return true;
        })()
        """
    }

    func takeSnapshot(_ completion: @escaping (NSImage?) -> Void) {
        if let session = freshMojoSession,
           let freshMojoRuntime {
            let snapshot = {
                if let image = freshMojoRuntime.captureSurfaceImage(session) {
                    completion(image)
                    return
                }
                self.takeLayerSnapshot(completion)
            }
            if Thread.isMainThread {
                snapshot()
            } else {
                DispatchQueue.main.async(execute: snapshot)
            }
            return
        }

        evaluateJavaScript("document.documentElement.outerHTML") { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.takeLayerSnapshot(completion)
            }
        }
    }

    private func takeLayerSnapshot(_ completion: @escaping (NSImage?) -> Void) {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            completion(nil)
            return
        }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        completion(image)
    }

    override func mouseDown(with event: NSEvent) { postMouseEvent(event, type: .leftMouseDown) }
    override func mouseUp(with event: NSEvent) { postMouseEvent(event, type: .leftMouseUp) }
    override func mouseDragged(with event: NSEvent) { postMouseEvent(event, type: .leftMouseDragged) }
    override func mouseMoved(with event: NSEvent) { postMouseEvent(event, type: .mouseMoved) }
    override func rightMouseDown(with event: NSEvent) { postMouseEvent(event, type: .rightMouseDown) }
    override func rightMouseUp(with event: NSEvent) { postMouseEvent(event, type: .rightMouseUp) }
    override func scrollWheel(with event: NSEvent) { postScrollEvent(event) }
    override func keyDown(with event: NSEvent) { postKeyEvent(event) }
    override func keyUp(with event: NSEvent) { postKeyEvent(event) }
    override func flagsChanged(with event: NSEvent) { postModifierKeyEvent(event) }

    private static func proxyServer(from proxyConfiguration: NSDictionary?) -> String? {
        guard let rawValue = proxyConfiguration?["proxyServer"] as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func recordNavigation(_ url: URL) {
        if navigationHistory.indices.contains(navigationHistoryIndex),
           navigationHistory[navigationHistoryIndex] == url {
            updateNavigationFlags()
            return
        }
        if navigationHistoryIndex >= 0, navigationHistoryIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((navigationHistoryIndex + 1)..<navigationHistory.count)
        }
        navigationHistory.append(url)
        navigationHistoryIndex = navigationHistory.count - 1
        updateNavigationFlags()
    }

    private func stepNavigationHistory(delta: Int) -> URL? {
        let nextIndex = navigationHistoryIndex + delta
        guard navigationHistory.indices.contains(nextIndex) else {
            updateNavigationFlags()
            return nil
        }
        navigationHistoryIndex = nextIndex
        currentURL = navigationHistory[nextIndex]
        updateNavigationFlags()
        notifyStateChanged()
        return navigationHistory[nextIndex]
    }

    private func updateNavigationFlags() {
        canGoBack = navigationHistory.indices.contains(navigationHistoryIndex - 1)
        canGoForward = navigationHistory.indices.contains(navigationHistoryIndex + 1)
    }

    private func launchIfPossible() {
        guard process == nil,
              freshMojoSession == nil,
              let pendingURL,
              window != nil,
              bounds.width >= 8,
              bounds.height >= 8 else { return }
        launch(url: pendingURL)
    }

    private func restartForPendingURL() {
        teardownProcessOnly()
        launchIfPossible()
    }

    private func launch(url: URL) {
        guard let executableURL = Self.contentShellExecutableURL() else {
            currentTitle = Self.browserEngineUnavailableTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
            return
        }

        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: contextFile)
            try? FileManager.default.removeItem(at: resizeFile)
            try? FileManager.default.removeItem(at: controlSocketFile)
            controlChannel.close()
        } catch {
            cmuxChromiumLogger.error("Failed to prepare browser session directory: \(error.localizedDescription, privacy: .private)")
            currentTitle = Self.browserEngineUnavailableTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
            return
        }

        if let freshMojoRuntime {
            launchFreshMojo(url: url, executableURL: executableURL, runtime: freshMojoRuntime)
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        process.arguments = [
            "--content-shell-hide-toolbar",
            "--cmux-embed",
            "--remote-debugging-port=0",
            "--user-data-dir=\(sessionDirectory.path)",
            "--content-shell-host-window-size=\(max(8, Int(bounds.width)))x\(max(8, Int(bounds.height)))",
            url.absoluteString
        ]
        if let proxyServer {
            process.arguments?.insert("--proxy-server=\(proxyServer)", at: max(0, (process.arguments?.count ?? 1) - 1))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CA_CONTEXT_FILE"] = contextFile.path
        environment["CMUX_CA_RESIZE_SOCK"] = controlSocketFile.path
        environment["CMUX_CA_RESIZE_FILE"] = resizeFile.path
        environment["CMUX_PROFILE_IDENTIFIER"] = profileIdentifier
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.parseProcessOutput(text)
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.clearProcessRuntimeState()
                self.notifyStateChanged()
            }
        }

        do {
            try process.run()
            self.process = process
            ioPipe = pipe
            launchedURL = url
            contentShellPID = process.processIdentifier
            isLoading = true
            estimatedProgress = 0.1
            startPollingContextFile()
            writeResizeIfNeeded(force: true)
            notifyStateChanged()
        } catch {
            cmuxChromiumLogger.error("Failed to launch browser process: \(error.localizedDescription, privacy: .private)")
            currentTitle = Self.browserEngineFailedTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
        }
    }

    private func launchFreshMojo(url: URL, executableURL: URL, runtime: OwlFreshMojoRuntime) {
        guard runtime.initialize() else {
            currentTitle = Self.browserEngineFailedTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
            return
        }

        let userData = Unmanaged.passRetained(self).toOpaque()
        freshMojoUserDataPointer = userData
        guard let session = runtime.createSession(
            contentShellPath: executableURL.path,
            initialURL: url.absoluteString,
            userDataDirectory: sessionDirectory.path,
            proxyServer: proxyServer,
            callback: Self.freshMojoEventCallback,
            userData: userData
        ) else {
            releaseFreshMojoUserDataPointer()
            currentTitle = Self.browserEngineFailedTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
            return
        }

        freshMojoSession = session
        launchedURL = url
        contentShellPID = pid_t(runtime.hostPID(session))
        isLoading = true
        estimatedProgress = 0.1

        let bindResult = runtime.bindDefaultInterfaces(session)
        if case .failure(let error) = bindResult {
            cmuxChromiumLogger.error("Failed to bind browser interfaces: \(error.localizedDescription, privacy: .private)")
            runtime.destroySession(session)
            freshMojoSession = nil
            releaseFreshMojoUserDataPointer()
            contentShellPID = 0
            currentTitle = Self.browserEngineFailedTitle()
            isLoading = false
            estimatedProgress = 0
            notifyStateChanged()
            return
        }

        startFreshMojoPolling()
        _ = runtime.flush(session)
        writeResizeIfNeeded(force: true)
        _ = runtime.setFocus(session, focused: window?.firstResponder === self)
        notifyStateChanged()
    }

    private static let freshMojoEventCallback: OwlFreshMojoEventCallback = { eventPointer, userData in
        guard let eventPointer,
              let userData else { return }
        let view = Unmanaged<CmuxChromiumBrowserView>
            .fromOpaque(userData)
            .takeUnretainedValue()
        view.handleFreshMojoEvent(eventPointer.assumingMemoryBound(to: OwlFreshMojoEvent.self).pointee)
    }

    private func startFreshMojoPolling() {
        freshMojoPollTimer?.invalidate()
        freshMojoPollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.freshMojoRuntime?.pollEvents(timeoutMilliseconds: 0)
        }
    }

    private func handleFreshMojoEvent(_ event: OwlFreshMojoEvent) {
        let kind = OwlFreshMojoEventKind(rawValue: event.kind)
        let message = event.message.map { String(cString: $0) }
        let urlString = event.url.map { String(cString: $0) }
        let title = event.title.map { String(cString: $0) }
        let contextID = event.contextID
        let hostPID = event.hostPID
        let loading = event.loading

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch kind {
            case .ready, .compositor:
                if hostPID > 0 {
                    self.contentShellPID = pid_t(hostPID)
                }
                if contextID != 0 {
                    self.currentContextID = contextID
                    self.attachHostLayer(contextID: contextID)
                    self.estimatedProgress = max(self.estimatedProgress, 0.8)
                    self.applyPersistentBrowserState()
                }
            case .navigation:
                if let urlString, let url = URL(string: urlString) {
                    self.currentURL = url
                    self.launchedURL = url
                    self.recordNavigation(url)
                    self.lastPersistentStateKey = nil
                }
                if let title, !title.isEmpty {
                    self.currentTitle = title
                }
                self.isLoading = loading
                self.estimatedProgress = loading ? max(self.estimatedProgress, 0.4) : 1
                if !loading {
                    self.applyPersistentBrowserState()
                }
            case .disconnected:
                self.isLoading = false
                self.estimatedProgress = 0
                self.freshMojoSession = nil
                self.freshMojoPollTimer?.invalidate()
                self.freshMojoPollTimer = nil
                self.releaseFreshMojoUserDataPointer()
            case .log, .surfaceTree, .none:
                if kind == .log, let message {
                    cmuxChromiumLogger.debug("Runtime log: \(message, privacy: .private)")
                }
            }
            self.notifyStateChanged()
        }
    }

    private func startPollingContextFile() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.readContextIDIfAvailable()
        }
    }

    private func readContextIDIfAvailable() {
        guard let text = try? String(contentsOf: contextFile, encoding: .utf8),
              let contextID = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              contextID != 0 else { return }
        if contextID == currentContextID {
            applyPersistentBrowserState()
            return
        }
        currentContextID = contextID
        attachHostLayer(contextID: contextID)
        isLoading = false
        estimatedProgress = 1
        applyPersistentBrowserState()
        notifyStateChanged()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.readContextIDIfAvailable()
        }
    }

    private func attachHostLayer(contextID: UInt32) {
        guard let cls = NSClassFromString("CALayerHost") as? CALayer.Type else { return }
        let host = cls.init()
        host.setValue(NSNumber(value: contextID), forKey: "contextId")
        host.frame = bounds
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer?.removeFromSuperlayer()
        layer?.addSublayer(host)
        hostLayer = host
        CATransaction.commit()
    }

    private func writeResizeIfNeeded(force: Bool = false) {
        guard process != nil || freshMojoSession != nil else { return }
        let size = NSSize(width: max(8, bounds.width), height: max(8, bounds.height))
        guard force || size != lastResizeSize else { return }
        lastResizeSize = size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.resize(
               session,
               width: UInt32(clamping: Int(size.width.rounded(.up))),
               height: UInt32(clamping: Int(size.height.rounded(.up))),
               scale: Float(scale)
           ) {
            return
        }
        if controlChannel.sendResize(
            width: UInt32(clamping: Int(size.width.rounded(.up))),
            height: UInt32(clamping: Int(size.height.rounded(.up))),
            scale: scale
        ) {
            return
        }
        let payload = "\(Int(size.width)) \(Int(size.height))\n"
        try? payload.write(to: resizeFile, atomically: true, encoding: .utf8)
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.stateChangedHandler?()
        }
    }

    private func parseProcessOutput(_ text: String) {
        if text.contains("[owl] listening") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.controlChannel.connectIfNeeded() {
                    self.writeResizeIfNeeded(force: true)
                    _ = self.controlChannel.sendFocus(self.window?.firstResponder === self)
                }
            }
        }

        guard let range = text.range(
            of: #"ws://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/devtools/browser/[A-Za-z0-9\-]+"#,
            options: .regularExpression
        ) else {
            return
        }
        let value = String(text[range])
        guard let url = URL(string: value),
              let port = url.port else { return }
        devToolsQueue.async { [weak self] in
            self?.devToolsPort = port
            self?.devToolsPageWebSocketURL = nil
        }
    }

    private func ensureDevToolsPageWebSocketURL(
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if let url = devToolsPageWebSocketURL {
            completion(.success(url))
            return
        }
        guard let port = devToolsPort,
              let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
            completion(.failure(CmuxChromiumCoreError.devToolsUnavailable))
            return
        }
        URLSession.shared.dataTask(with: listURL) { data, _, error in
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let page = entries.first(where: { ($0["type"] as? String) == "page" }),
                      let webSocket = page["webSocketDebuggerUrl"] as? String,
                      let url = URL(string: webSocket) {
                result = .success(url)
            } else {
                result = .failure(CmuxChromiumCoreError.devToolsUnavailable)
            }
            self.devToolsQueue.async { [weak self] in
                if case .success(let url) = result {
                    self?.devToolsPageWebSocketURL = url
                }
                completion(result)
            }
        }.resume()
    }

    private func sendDevToolsCommand(
        webSocketURL: URL,
        method: String,
        params: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let commandID = 1
        let lock = NSLock()
        var didFinish = false
        let message: [String: Any] = [
            "id": commandID,
            "method": method,
            "params": params
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            completion(.failure(CmuxChromiumCoreError.invalidDevToolsResponse))
            return
        }

        let task = URLSession.shared.webSocketTask(with: webSocketURL)
        task.resume()
        var timeoutWorkItem: DispatchWorkItem?

        let finish: (Result<[String: Any], Error>) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            guard !didFinish else { return }
            didFinish = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            task.cancel(with: .normalClosure, reason: nil)
            completion(result)
        }
        let workItem = DispatchWorkItem {
            finish(.failure(CmuxChromiumCoreError.devToolsError("Timed out waiting for browser script response")))
        }
        timeoutWorkItem = workItem
        devToolsQueue.asyncAfter(deadline: .now() + 5, execute: workItem)

        let objectFromMessage: (URLSessionWebSocketTask.Message) -> [String: Any]? = { message in
            let data: Data?
            switch message {
            case .string(let text):
                data = text.data(using: .utf8)
            case .data(let value):
                data = value
            @unknown default:
                data = nil
            }
            guard let data else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        func receiveNextResponse() {
            task.receive { result in
                switch result {
                case .failure(let error):
                    finish(.failure(error))
                case .success(let message):
                    guard let object = objectFromMessage(message) else {
                        finish(.failure(CmuxChromiumCoreError.invalidDevToolsResponse))
                        return
                    }
                    let responseID: Int? = {
                        if let value = object["id"] as? Int { return value }
                        if let value = object["id"] as? NSNumber { return value.intValue }
                        return nil
                    }()
                    guard responseID == commandID else {
                        receiveNextResponse()
                        return
                    }
                    if let error = object["error"] {
                        finish(.failure(CmuxChromiumCoreError.devToolsError(String(describing: error))))
                        return
                    }
                    finish(.success((object["result"] as? [String: Any]) ?? [:]))
                }
            }
        }

        task.send(.string(text)) { error in
            if let error {
                finish(.failure(error))
                return
            }
            receiveNextResponse()
        }
    }

    private func postMouseEvent(_ event: NSEvent, type: CGEventType) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        let mouseType: UInt8
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mouseType = OwlMouseType.down.rawValue
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mouseType = OwlMouseType.up.rawValue
        default:
            mouseType = OwlMouseType.move.rawValue
        }
        let button: UInt8
        if type == .rightMouseDown || type == .rightMouseUp {
            button = OwlMouseButton.right.rawValue
        } else if event.buttonNumber == 2 || type == .otherMouseDown || type == .otherMouseUp {
            button = OwlMouseButton.middle.rawValue
        } else {
            button = OwlMouseButton.left.rawValue
        }
        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.sendMouse(
               session,
               kind: UInt32(mouseType),
               x: Float(local.x),
               y: Float(max(0, bounds.height - local.y)),
               button: UInt32(button),
               clickCount: UInt32(clamping: event.clickCount),
               deltaX: 0,
               deltaY: 0,
               modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
           ) {
            return
        }
        controlChannel.sendMouseAsync(
            type: mouseType,
            x: Double(local.x),
            y: Double(max(0, bounds.height - local.y)),
            button: button,
            clickCount: UInt8(clamping: event.clickCount),
            deltaX: 0,
            deltaY: 0,
            modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
        )
    }

    private func postScrollEvent(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.sendMouse(
               session,
               kind: UInt32(OwlMouseType.wheel.rawValue),
               x: Float(local.x),
               y: Float(max(0, bounds.height - local.y)),
               button: UInt32(OwlMouseButton.left.rawValue),
               clickCount: 0,
               deltaX: Float(event.scrollingDeltaX),
               deltaY: Float(event.scrollingDeltaY),
               modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
           ) {
            return
        }
        controlChannel.sendMouseAsync(
            type: OwlMouseType.wheel.rawValue,
            x: Double(local.x),
            y: Double(max(0, bounds.height - local.y)),
            button: OwlMouseButton.left.rawValue,
            clickCount: 0,
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
        )
    }

    private func postKeyEvent(_ event: NSEvent) {
        let keyType: UInt8
        switch event.type {
        case .keyDown:
            keyType = OwlKeyType.down.rawValue
        case .keyUp:
            keyType = OwlKeyType.up.rawValue
        default:
            return
        }
        postKey(
            type: keyType,
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            modifiers: event.modifierFlags
        )
    }

    private func postModifierKeyEvent(_ event: NSEvent) {
        guard let modifierFlag = Self.modifierFlag(forKeyCode: event.keyCode) else { return }
        let keyType = event.modifierFlags.contains(modifierFlag)
            ? OwlKeyType.down.rawValue
            : OwlKeyType.up.rawValue
        postKey(type: keyType, keyCode: event.keyCode, characters: "", modifiers: event.modifierFlags)
    }

    private static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            return .command
        case 56, 60:
            return .shift
        case 57:
            return .capsLock
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 63:
            return .function
        default:
            return nil
        }
    }

    private func postKey(
        type keyType: UInt8,
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        if let session = freshMojoSession,
           let freshMojoRuntime,
           freshMojoRuntime.sendKey(
               session,
               keyDown: keyType == OwlKeyType.down.rawValue,
               keyCode: UInt32(keyCode),
               text: characters,
               modifiers: UInt32(truncatingIfNeeded: modifiers.rawValue)
           ) {
            return
        }
        controlChannel.sendKeyAsync(
            type: keyType,
            keyCode: keyCode,
            characters: characters,
            modifiers: UInt32(truncatingIfNeeded: modifiers.rawValue)
        )
    }

    private func teardown() {
        teardownProcessOnly()
        try? FileManager.default.removeItem(at: contextFile)
        try? FileManager.default.removeItem(at: resizeFile)
        try? FileManager.default.removeItem(at: controlSocketFile)
    }

    private func teardownProcessOnly() {
        freshMojoPollTimer?.invalidate()
        freshMojoPollTimer = nil
        if let session = freshMojoSession {
            freshMojoRuntime?.destroySession(session)
            freshMojoSession = nil
            releaseFreshMojoUserDataPointer()
        }
        pollTimer?.invalidate()
        pollTimer = nil
        ioPipe?.fileHandleForReading.readabilityHandler = nil
        ioPipe = nil
        process?.terminate()
        clearProcessRuntimeState()
    }

    private func clearProcessRuntimeState() {
        process = nil
        controlChannel.close()
        contentShellPID = 0
        currentContextID = 0
        devToolsPort = nil
        devToolsPageWebSocketURL = nil
        hostLayer?.removeFromSuperlayer()
        hostLayer = nil
        launchedURL = nil
        isLoading = false
        estimatedProgress = 0
    }

    private func releaseFreshMojoUserDataPointer() {
        guard let pointer = freshMojoUserDataPointer else { return }
        Unmanaged<CmuxChromiumBrowserView>.fromOpaque(pointer).release()
        freshMojoUserDataPointer = nil
    }

    private static func browserEngineUnavailableTitle() -> String {
        String(localized: "browser.chromium.error.unavailable", defaultValue: "Browser engine unavailable")
    }

    private static func browserEngineFailedTitle() -> String {
        String(localized: "browser.chromium.error.failedToStart", defaultValue: "Browser engine failed to start")
    }

    fileprivate static func browserScriptFailedTitle() -> String {
        String(localized: "browser.chromium.error.scriptFailed", defaultValue: "Browser script failed")
    }

    private static func contentShellExecutableURL() -> URL? {
        guard let resourceURL = Bundle(for: CmuxChromiumBrowserHost.self).resourceURL else {
            return nil
        }
        let executableURL = resourceURL
            .appendingPathComponent("Content Shell.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/Content Shell", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return executableURL
    }
}

enum CmuxChromiumCoreError: LocalizedError {
    case devToolsUnavailable
    case invalidDevToolsResponse
    case devToolsError(String)

    var errorDescription: String? {
        switch self {
        case .devToolsUnavailable:
            return CmuxChromiumBrowserView.browserScriptFailedTitle()
        case .invalidDevToolsResponse:
            return CmuxChromiumBrowserView.browserScriptFailedTitle()
        case .devToolsError(let message):
            cmuxChromiumLogger.error("DevTools error: \(message, privacy: .private)")
            return CmuxChromiumBrowserView.browserScriptFailedTitle()
        }
    }
}

private enum OwlFreshMojoEventKind: Int32 {
    case log = 1
    case ready = 2
    case compositor = 3
    case navigation = 4
    case disconnected = 5
    case surfaceTree = 6
}

private struct OwlFreshMojoEvent {
    var kind: Int32
    var contextID: UInt32
    var hostPID: Int32
    var loading: Bool
    var url: UnsafePointer<CChar>?
    var title: UnsafePointer<CChar>?
    var message: UnsafePointer<CChar>?
}

private typealias OwlFreshMojoEventCallback = @convention(c) (
    UnsafeRawPointer?,
    UnsafeMutableRawPointer?
) -> Void

private final class OwlFreshMojoRuntime {
    private typealias GlobalInit = @convention(c) () -> Int32
    private typealias SessionCreate = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        OwlFreshMojoEventCallback?,
        UnsafeMutableRawPointer?
    ) -> OpaquePointer?
    private typealias SessionCreateWithProxy = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        OwlFreshMojoEventCallback?,
        UnsafeMutableRawPointer?
    ) -> OpaquePointer?
    private typealias SessionDestroy = @convention(c) (OpaquePointer?) -> Void
    private typealias SessionHostPID = @convention(c) (OpaquePointer?) -> Int32
    private typealias BindInterface = @convention(c) (
        OpaquePointer?,
        UInt64,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias Flush = @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<Bool>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias ExecuteJavaScript = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias Navigate = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias Resize = @convention(c) (
        OpaquePointer?,
        UInt32,
        UInt32,
        Float,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias SetFocus = @convention(c) (
        OpaquePointer?,
        Bool,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias SendMouse = @convention(c) (
        OpaquePointer?,
        UInt32,
        Float,
        Float,
        UInt32,
        UInt32,
        Float,
        Float,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias SendKey = @convention(c) (
        OpaquePointer?,
        Bool,
        UInt32,
        UnsafePointer<CChar>?,
        UInt32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias CaptureSurface = @convention(c) (
        OpaquePointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias PollEvents = @convention(c) (UInt32) -> Void
    private typealias FreeBuffer = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let handle: UnsafeMutableRawPointer
    private let globalInit: GlobalInit
    private let sessionCreate: SessionCreate
    private let sessionCreateWithProxy: SessionCreateWithProxy?
    private let sessionDestroy: SessionDestroy
    private let sessionHostPID: SessionHostPID
    private let sessionSetClient: BindInterface
    private let bindProfile: BindInterface
    private let bindWebView: BindInterface
    private let bindInput: BindInterface
    private let bindSurfaceTree: BindInterface
    private let bindNativeSurfaceHost: BindInterface
    private let bindDevToolsHost: BindInterface
    private let sessionFlush: Flush
    private let shellExecuteJavaScript: ExecuteJavaScript
    private let webViewNavigate: Navigate
    private let webViewResize: Resize
    private let webViewSetFocus: SetFocus
    private let inputSendMouse: SendMouse
    private let inputSendKey: SendKey
    private let surfaceTreeCaptureSurfaceJSON: CaptureSurface
    private let pollEventsFunction: PollEvents
    private let freeBuffer: FreeBuffer

    private init?(
        handle: UnsafeMutableRawPointer,
        globalInit: GlobalInit,
        sessionCreate: SessionCreate,
        sessionCreateWithProxy: SessionCreateWithProxy?,
        sessionDestroy: SessionDestroy,
        sessionHostPID: SessionHostPID,
        sessionSetClient: BindInterface,
        bindProfile: BindInterface,
        bindWebView: BindInterface,
        bindInput: BindInterface,
        bindSurfaceTree: BindInterface,
        bindNativeSurfaceHost: BindInterface,
        bindDevToolsHost: BindInterface,
        sessionFlush: Flush,
        shellExecuteJavaScript: ExecuteJavaScript,
        webViewNavigate: Navigate,
        webViewResize: Resize,
        webViewSetFocus: SetFocus,
        inputSendMouse: SendMouse,
        inputSendKey: SendKey,
        surfaceTreeCaptureSurfaceJSON: CaptureSurface,
        pollEventsFunction: PollEvents,
        freeBuffer: FreeBuffer
    ) {
        self.handle = handle
        self.globalInit = globalInit
        self.sessionCreate = sessionCreate
        self.sessionCreateWithProxy = sessionCreateWithProxy
        self.sessionDestroy = sessionDestroy
        self.sessionHostPID = sessionHostPID
        self.sessionSetClient = sessionSetClient
        self.bindProfile = bindProfile
        self.bindWebView = bindWebView
        self.bindInput = bindInput
        self.bindSurfaceTree = bindSurfaceTree
        self.bindNativeSurfaceHost = bindNativeSurfaceHost
        self.bindDevToolsHost = bindDevToolsHost
        self.sessionFlush = sessionFlush
        self.shellExecuteJavaScript = shellExecuteJavaScript
        self.webViewNavigate = webViewNavigate
        self.webViewResize = webViewResize
        self.webViewSetFocus = webViewSetFocus
        self.inputSendMouse = inputSendMouse
        self.inputSendKey = inputSendKey
        self.surfaceTreeCaptureSurfaceJSON = surfaceTreeCaptureSurfaceJSON
        self.pollEventsFunction = pollEventsFunction
        self.freeBuffer = freeBuffer
    }

    static func load() -> OwlFreshMojoRuntime? {
        guard let resourceURL = Bundle(for: CmuxChromiumBrowserHost.self).resourceURL else {
            return nil
        }
        let dylibURL = resourceURL.appendingPathComponent("libowl_fresh_mojo_runtime.dylib")
        guard FileManager.default.fileExists(atPath: dylibURL.path),
              let handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let globalInit = symbol("owl_fresh_mojo_global_init", as: GlobalInit.self),
            let sessionCreate = symbol("owl_fresh_mojo_session_create", as: SessionCreate.self),
            let sessionDestroy = symbol("owl_fresh_mojo_session_destroy", as: SessionDestroy.self),
            let sessionHostPID = symbol("owl_fresh_mojo_session_host_pid", as: SessionHostPID.self),
            let sessionSetClient = symbol("owl_fresh_mojo_session_set_client", as: BindInterface.self),
            let bindProfile = symbol("owl_fresh_mojo_session_bind_profile", as: BindInterface.self),
            let bindWebView = symbol("owl_fresh_mojo_session_bind_web_view", as: BindInterface.self),
            let bindInput = symbol("owl_fresh_mojo_session_bind_input", as: BindInterface.self),
            let bindSurfaceTree = symbol("owl_fresh_mojo_session_bind_surface_tree", as: BindInterface.self),
            let bindNativeSurfaceHost = symbol("owl_fresh_mojo_session_bind_native_surface_host", as: BindInterface.self),
            let bindDevToolsHost = symbol("owl_fresh_mojo_session_bind_devtools_host", as: BindInterface.self),
            let sessionFlush = symbol("owl_fresh_mojo_session_flush", as: Flush.self),
            let shellExecuteJavaScript = symbol("owl_fresh_mojo_shell_execute_javascript", as: ExecuteJavaScript.self),
            let webViewNavigate = symbol("owl_fresh_mojo_web_view_navigate", as: Navigate.self),
            let webViewResize = symbol("owl_fresh_mojo_web_view_resize", as: Resize.self),
            let webViewSetFocus = symbol("owl_fresh_mojo_web_view_set_focus", as: SetFocus.self),
            let inputSendMouse = symbol("owl_fresh_mojo_input_send_mouse", as: SendMouse.self),
            let inputSendKey = symbol("owl_fresh_mojo_input_send_key", as: SendKey.self),
            let surfaceTreeCaptureSurfaceJSON = symbol(
                "owl_fresh_mojo_surface_tree_capture_surface_json",
                as: CaptureSurface.self
            ),
            let pollEventsFunction = symbol("owl_fresh_mojo_poll_events", as: PollEvents.self),
            let freeBuffer = symbol("owl_fresh_mojo_free_buffer", as: FreeBuffer.self)
        else {
            dlclose(handle)
            return nil
        }
        let sessionCreateWithProxy = symbol(
            "owl_fresh_mojo_session_create_with_proxy",
            as: SessionCreateWithProxy.self
        )

        return OwlFreshMojoRuntime(
            handle: handle,
            globalInit: globalInit,
            sessionCreate: sessionCreate,
            sessionCreateWithProxy: sessionCreateWithProxy,
            sessionDestroy: sessionDestroy,
            sessionHostPID: sessionHostPID,
            sessionSetClient: sessionSetClient,
            bindProfile: bindProfile,
            bindWebView: bindWebView,
            bindInput: bindInput,
            bindSurfaceTree: bindSurfaceTree,
            bindNativeSurfaceHost: bindNativeSurfaceHost,
            bindDevToolsHost: bindDevToolsHost,
            sessionFlush: sessionFlush,
            shellExecuteJavaScript: shellExecuteJavaScript,
            webViewNavigate: webViewNavigate,
            webViewResize: webViewResize,
            webViewSetFocus: webViewSetFocus,
            inputSendMouse: inputSendMouse,
            inputSendKey: inputSendKey,
            surfaceTreeCaptureSurfaceJSON: surfaceTreeCaptureSurfaceJSON,
            pollEventsFunction: pollEventsFunction,
            freeBuffer: freeBuffer
        )
    }

    func initialize() -> Bool {
        globalInit() == 0
    }

    func createSession(
        contentShellPath: String,
        initialURL: String,
        userDataDirectory: String,
        proxyServer: String?,
        callback: OwlFreshMojoEventCallback,
        userData: UnsafeMutableRawPointer
    ) -> OpaquePointer? {
        contentShellPath.withCString { contentShellPathPointer in
            initialURL.withCString { initialURLPointer in
                userDataDirectory.withCString { userDataDirectoryPointer in
                    if let sessionCreateWithProxy {
                        if let proxyServer {
                            return proxyServer.withCString { proxyServerPointer in
                                sessionCreateWithProxy(
                                    contentShellPathPointer,
                                    initialURLPointer,
                                    userDataDirectoryPointer,
                                    proxyServerPointer,
                                    callback,
                                    userData
                                )
                            }
                        }
                        return sessionCreateWithProxy(
                            contentShellPathPointer,
                            initialURLPointer,
                            userDataDirectoryPointer,
                            nil,
                            callback,
                            userData
                        )
                    }
                    guard proxyServer == nil else { return nil }
                    return sessionCreate(
                        contentShellPathPointer,
                        initialURLPointer,
                        userDataDirectoryPointer,
                        callback,
                        userData
                    )
                }
            }
        }
    }

    func destroySession(_ session: OpaquePointer) {
        sessionDestroy(session)
    }

    func hostPID(_ session: OpaquePointer) -> Int32 {
        sessionHostPID(session)
    }

    func bindDefaultInterfaces(_ session: OpaquePointer) -> Result<Void, Error> {
        let binds: [(UInt64, BindInterface)] = [
            (1, sessionSetClient),
            (2, bindProfile),
            (3, bindWebView),
            (4, bindInput),
            (5, bindSurfaceTree),
            (6, bindNativeSurfaceHost),
            (7, bindDevToolsHost)
        ]
        for (handle, bind) in binds {
            var error: UnsafeMutablePointer<CChar>?
            let status = bind(session, handle, &error)
            if status != 0 {
                return .failure(CmuxChromiumCoreError.devToolsError(consumeCString(error) ?? "Browser interface bind failed"))
            }
        }
        return .success(())
    }

    func flush(_ session: OpaquePointer) -> Bool {
        var ok = false
        var error: UnsafeMutablePointer<CChar>?
        let status = sessionFlush(session, &ok, &error)
        consumeCString(error)
        return status == 0 && ok
    }

    func navigate(_ session: OpaquePointer, url: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = url.withCString { webViewNavigate(session, $0, &error) }
        consumeCString(error)
        return status == 0
    }

    func resize(_ session: OpaquePointer, width: UInt32, height: UInt32, scale: Float) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = webViewResize(session, width, height, scale, &error)
        consumeCString(error)
        return status == 0
    }

    func setFocus(_ session: OpaquePointer, focused: Bool) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = webViewSetFocus(session, focused, &error)
        consumeCString(error)
        return status == 0
    }

    func sendMouse(
        _ session: OpaquePointer,
        kind: UInt32,
        x: Float,
        y: Float,
        button: UInt32,
        clickCount: UInt32,
        deltaX: Float,
        deltaY: Float,
        modifiers: UInt32
    ) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = inputSendMouse(
            session,
            kind,
            x,
            y,
            button,
            clickCount,
            deltaX,
            deltaY,
            modifiers,
            &error
        )
        consumeCString(error)
        return status == 0
    }

    func sendKey(
        _ session: OpaquePointer,
        keyDown: Bool,
        keyCode: UInt32,
        text: String,
        modifiers: UInt32
    ) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        let status = text.withCString {
            inputSendKey(session, keyDown, keyCode, $0, modifiers, &error)
        }
        consumeCString(error)
        return status == 0
    }

    func executeJavaScript(_ session: OpaquePointer, script: String) -> Result<Any?, Error> {
        var result: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = script.withCString {
            shellExecuteJavaScript(session, $0, &result, &error)
        }
        if status != 0 {
            return .failure(CmuxChromiumCoreError.devToolsError(consumeCString(error) ?? "Browser JavaScript execution failed"))
        }
        consumeCString(error)
        guard let json = consumeCString(result) else {
            return .success(nil)
        }
        guard let data = json.data(using: .utf8) else {
            return .success(json)
        }
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return .success(value)
    }

    func captureSurfaceImage(_ session: OpaquePointer) -> NSImage? {
        var result: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = surfaceTreeCaptureSurfaceJSON(session, &result, &error)
        consumeCString(error)
        guard status == 0,
              let json = consumeCString(result),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = object["pngBase64"] as? String,
              let pngData = Data(base64Encoded: base64) else {
            return nil
        }
        return NSImage(data: pngData)
    }

    func pollEvents(timeoutMilliseconds: UInt32) {
        pollEventsFunction(timeoutMilliseconds)
    }

    @discardableResult
    private func consumeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeBuffer(pointer) }
        return String(cString: pointer)
    }
}

private enum OwlOperation: UInt8 {
    case resize = 0x02
    case mouse = 0x03
    case key = 0x04
    case focus = 0x05
    case navigate = 0x06
    case goBack = 0x07
    case goForward = 0x08
    case reload = 0x09
    case stop = 0x0A
}

private enum OwlMouseType: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case wheel = 3
}

private enum OwlMouseButton: UInt8 {
    case left = 0
    case middle = 1
    case right = 2
}

private enum OwlKeyType: UInt8 {
    case down = 0
    case up = 1
}

private final class OwlControlChannel {
    private let path: String
    private let lock = NSLock()
    private let asyncQueue = DispatchQueue(label: "cmux.chromium.control-channel")
    private var socketFD: Int32 = -1
    private var nextRequestID: UInt32 = 1

    init(path: String) {
        self.path = path
    }

    func connectIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connectIfNeededLocked()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    func sendResize(width: UInt32, height: UInt32, scale: Double) -> Bool {
        var payload = OwlPayloadWriter()
        payload.writeUInt32(width)
        payload.writeUInt32(height)
        payload.writeFloat64(scale)
        return send(.resize, payload: payload.data)
    }

    func sendMouse(
        type: UInt8,
        x: Double,
        y: Double,
        button: UInt8,
        clickCount: UInt8,
        deltaX: Double,
        deltaY: Double,
        modifiers: UInt32
    ) -> Bool {
        var payload = OwlPayloadWriter()
        payload.writeUInt8(type)
        payload.writeFloat64(x)
        payload.writeFloat64(y)
        payload.writeUInt8(button)
        payload.writeUInt8(clickCount)
        payload.writeFloat64(deltaX)
        payload.writeFloat64(deltaY)
        payload.writeUInt32(modifiers)
        return send(.mouse, payload: payload.data)
    }

    func sendMouseAsync(
        type: UInt8,
        x: Double,
        y: Double,
        button: UInt8,
        clickCount: UInt8,
        deltaX: Double,
        deltaY: Double,
        modifiers: UInt32
    ) {
        var payload = OwlPayloadWriter()
        payload.writeUInt8(type)
        payload.writeFloat64(x)
        payload.writeFloat64(y)
        payload.writeUInt8(button)
        payload.writeUInt8(clickCount)
        payload.writeFloat64(deltaX)
        payload.writeFloat64(deltaY)
        payload.writeUInt32(modifiers)
        sendAsync(.mouse, payload: payload.data)
    }

    func sendKey(type: UInt8, keyCode: UInt16, characters: String, modifiers: UInt32) -> Bool {
        var payload = OwlPayloadWriter()
        payload.writeUInt8(type)
        payload.writeUInt16(keyCode)
        payload.writeString(characters)
        payload.writeUInt32(modifiers)
        return send(.key, payload: payload.data)
    }

    func sendKeyAsync(type: UInt8, keyCode: UInt16, characters: String, modifiers: UInt32) {
        var payload = OwlPayloadWriter()
        payload.writeUInt8(type)
        payload.writeUInt16(keyCode)
        payload.writeString(characters)
        payload.writeUInt32(modifiers)
        sendAsync(.key, payload: payload.data)
    }

    func sendFocus(_ focused: Bool) -> Bool {
        var payload = OwlPayloadWriter()
        payload.writeUInt8(focused ? 1 : 0)
        return send(.focus, payload: payload.data)
    }

    func sendNavigate(_ url: String) -> Bool {
        var payload = OwlPayloadWriter()
        payload.writeString(url)
        return send(.navigate, payload: payload.data)
    }

    func sendGoBack() -> Bool {
        send(.goBack, payload: Data())
    }

    func sendGoForward() -> Bool {
        send(.goForward, payload: Data())
    }

    func sendReload() -> Bool {
        send(.reload, payload: Data())
    }

    func sendStop() -> Bool {
        send(.stop, payload: Data())
    }

    private func send(_ operation: OwlOperation, payload: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard connectIfNeededLocked() else { return false }

        let requestID = nextRequestID
        nextRequestID &+= 1

        var frame = Data()
        let innerLength = UInt32(1 + 4 + payload.count)
        OwlPayloadWriter.writeUInt32BE(innerLength, to: &frame)
        frame.append(contentsOf: [operation.rawValue])
        OwlPayloadWriter.writeUInt32(requestID, to: &frame)
        frame.append(payload)

        guard writeAllLocked(frame) else {
            closeLocked()
            return false
        }
        return true
    }

    private func sendAsync(_ operation: OwlOperation, payload: Data) {
        asyncQueue.async { [weak self] in
            _ = self?.send(operation, payload: payload)
        }
    }

    private func connectIfNeededLocked() -> Bool {
        if socketFD >= 0 { return true }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

#if os(macOS)
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            Darwin.close(fd)
            return false
        }
#endif

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= maxPathLength else {
            Darwin.close(fd)
            return false
        }

        let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { buffer in
                for index in 0..<pathBytes.count {
                    buffer[index] = CChar(bitPattern: pathBytes[index])
                }
                buffer[pathBytes.count] = 0
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            return false
        }

        socketFD = fd
        return true
    }

    private func writeAllLocked(_ data: Data) -> Bool {
        guard socketFD >= 0 else { return false }
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func closeLocked() {
        guard socketFD >= 0 else { return }
        Darwin.close(socketFD)
        socketFD = -1
    }
}

private struct OwlPayloadWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(contentsOf: [value])
    }

    mutating func writeUInt16(_ value: UInt16) {
        Self.writeUInt16(value, to: &data)
    }

    mutating func writeUInt32(_ value: UInt32) {
        Self.writeUInt32(value, to: &data)
    }

    mutating func writeFloat64(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    mutating func writeString(_ value: String) {
        let bytes = Array(value.utf8)
        writeUInt32(UInt32(clamping: bytes.count))
        data.append(contentsOf: bytes)
    }

    static func writeUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    static func writeUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    static func writeUInt32BE(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { buffer in
            data.append(contentsOf: buffer)
        }
    }
}
