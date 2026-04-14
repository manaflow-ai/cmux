import Foundation
import Combine
import AppKit
import Network
import WebKit

/// A panel that renders a markdown file with live file-watching.
/// When the file changes on disk, the content is automatically reloaded.
@MainActor
final class MarkdownPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .markdown

    /// Absolute path to the markdown file being displayed.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current markdown content read from the file.
    @Published private(set) var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.richtext" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - File watching

    // nonisolated(unsafe) because deinit is not guaranteed to run on the
    // main actor, but DispatchSource.cancel() is thread-safe.
    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.markdown-file-watch", qos: .utility)

    /// Maximum number of reattach attempts after a file delete/rename event.
    private static let maxReattachAttempts = 6
    /// Delay between reattach attempts (total window: attempts * delay = 3s).
    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            // Session restore can create a panel before the file is recreated.
            // Retry briefly so atomic-rename recreations can reconnect.
            scheduleReattach(attempt: 1)
        }
    }

    // MARK: - Panel protocol

    func focus() {
        // Markdown panel is read-only; no first responder to manage.
    }

    func unfocus() {
        // No-op for read-only panel.
    }

    func close() {
        isClosed = true
        stopFileWatcher()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            content = newContent
            isFileUnavailable = false
        } catch {
            // Fallback: try ISO Latin-1, which accepts all 256 byte values,
            // covering legacy encodings like Windows-1252.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                content = decoded
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was deleted or renamed. The old file descriptor points to
                // a stale inode, so we must always stop and reattach the watcher
                // even if the new file is already readable (atomic save case).
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    self.loadFileContent()
                    if self.isFileUnavailable {
                        // File not yet replaced — retry until it reappears.
                        self.scheduleReattach(attempt: 1)
                    } else {
                        // File already replaced — reattach to the new inode immediately.
                        self.startFileWatcher()
                    }
                }
            } else {
                // Content changed — reload.
                DispatchQueue.main.async {
                    self.loadFileContent()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Retry reattaching the file watcher up to `maxReattachAttempts` times.
    /// Each attempt checks if the file has reappeared. Bails out early if
    /// the panel has been closed.
    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    self.loadFileContent()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        // File descriptor is closed by the cancel handler.
        fileDescriptor = -1
    }

    deinit {
        // DispatchSource cancel is safe from any thread.
        fileWatchSource?.cancel()
    }
}

struct VncPanelTarget: Equatable, Sendable {
    static let defaultPort = 5900

    let host: String
    let port: Int

    var displayString: String {
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return port == Self.defaultPort ? host : "\(host):\(port)"
    }

    static func parse(_ rawInput: String) -> VncPanelTarget? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://"),
           let components = URLComponents(string: trimmed),
           let host = normalizedHost(components.host),
           let port = resolvedPort(components.port) {
            return VncPanelTarget(host: host, port: port)
        }

        return parseHostPortString(trimmed)
    }

    private static func parseHostPortString(_ input: String) -> VncPanelTarget? {
        if input.hasPrefix("["),
           let closeBracket = input.firstIndex(of: "]") {
            let hostSlice = input[input.index(after: input.startIndex)..<closeBracket]
            let remainder = input[input.index(after: closeBracket)...]
            let normalizedRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = normalizedHost(String(hostSlice)) else { return nil }

            if normalizedRemainder.isEmpty {
                return VncPanelTarget(host: host, port: defaultPort)
            }

            guard normalizedRemainder.hasPrefix(":") else { return nil }
            let portString = String(normalizedRemainder.dropFirst())
            guard let port = resolvedPort(Int(portString)) else { return nil }
            return VncPanelTarget(host: host, port: port)
        }

        let colonCount = input.reduce(into: 0) { count, character in
            if character == ":" {
                count += 1
            }
        }
        if colonCount == 1,
           let separator = input.firstIndex(of: ":") {
            let hostPart = String(input[..<separator])
            let portPart = String(input[input.index(after: separator)...])
            guard let host = normalizedHost(hostPart),
                  let port = resolvedPort(Int(portPart)) else {
                return nil
            }
            return VncPanelTarget(host: host, port: port)
        }

        guard let host = normalizedHost(input) else { return nil }
        return VncPanelTarget(host: host, port: defaultPort)
    }

    private static func normalizedHost(_ rawHost: String?) -> String? {
        guard let rawHost else { return nil }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func resolvedPort(_ candidate: Int?) -> Int? {
        guard let candidate else { return defaultPort }
        guard (1...65535).contains(candidate) else { return nil }
        return candidate
    }
}

struct VncDiscoveredTarget: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let endpoint: String
}

enum VncCredentialField: String, CaseIterable, Hashable, Sendable {
    case username
    case password
}

private enum VncRecentTargetsStore {
    private static let key = "vnc.recent.targets.v1"
    private static let maxCount = 20

    static func load() -> [String] {
        let defaults = UserDefaults.standard
        guard let saved = defaults.array(forKey: key) as? [String] else {
            return []
        }
        return saved
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func record(_ endpoint: String) {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var targets = load()
        targets.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        targets.insert(normalized, at: 0)
        if targets.count > maxCount {
            targets = Array(targets.prefix(maxCount))
        }
        UserDefaults.standard.set(targets, forKey: key)
    }
}

private enum VncSSHHostAliasResolver {
    static func resolve(host: String) async -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            resolveBlocking(host: trimmed)
        }.value
    }

    private static func resolveBlocking(host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", trimmed]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        let exitSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSignal.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitResult = exitSignal.wait(timeout: .now() + 3.0)
        if waitResult == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            _ = exitSignal.wait(timeout: .now() + 0.2)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return nil
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.lowercased().hasPrefix("hostname ") else { continue }
            let candidate = text.dropFirst("hostname ".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            if candidate.caseInsensitiveCompare(trimmed) == .orderedSame {
                return nil
            }
            return candidate
        }
        return nil
    }
}

private final class VncBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onTargetsChanged: (([VncDiscoveredTarget]) -> Void)?

    private let browser = NetServiceBrowser()
    private var servicesByID: [String: NetService] = [:]
    private var targetsByID: [String: VncDiscoveredTarget] = [:]
    private var isStarted = false

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        browser.stop()
        for service in servicesByID.values {
            service.stop()
            service.delegate = nil
        }
        servicesByID.removeAll()
        targetsByID.removeAll()
    }

    func netServiceBrowser(
        _: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let serviceID = Self.serviceIdentifier(for: service)
        servicesByID[serviceID] = service
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        if !moreComing {
            publishTargets()
        }
    }

    func netServiceBrowser(
        _: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let serviceID = Self.serviceIdentifier(for: service)
        servicesByID[serviceID]?.delegate = nil
        servicesByID.removeValue(forKey: serviceID)
        targetsByID.removeValue(forKey: serviceID)
        if !moreComing {
            publishTargets()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceID = Self.serviceIdentifier(for: sender)
        guard let hostName = sender.hostName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostName.isEmpty,
              sender.port > 0 else {
            return
        }

        let normalizedHost = hostName.hasSuffix(".")
            ? String(hostName.dropLast())
            : hostName
        let endpoint = sender.port == VncPanelTarget.defaultPort
            ? normalizedHost
            : "\(normalizedHost):\(sender.port)"

        targetsByID[serviceID] = VncDiscoveredTarget(
            id: serviceID,
            name: sender.name,
            endpoint: endpoint
        )
        publishTargets()
    }

    func netService(_ sender: NetService, didNotResolve _: [String: NSNumber]) {
        let serviceID = Self.serviceIdentifier(for: sender)
        targetsByID.removeValue(forKey: serviceID)
        publishTargets()
    }

    private func publishTargets() {
        let targets = targetsByID.values.sorted {
            let leftName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if leftName != .orderedSame { return leftName == .orderedAscending }
            return $0.endpoint.localizedCaseInsensitiveCompare($1.endpoint) == .orderedAscending
        }
        onTargetsChanged?(targets)
    }

    private static func serviceIdentifier(for service: NetService) -> String {
        let domain = service.domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(service.name.lowercased())|\(service.type.lowercased())|\(domain)"
    }
}

enum VncPanelConnectionState: String, Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case error
}

final class VncWebSocketProxyBridge {
    enum Event {
        case listenerReady(port: UInt16)
        case remoteConnected
        case remoteDisconnected
        case failed(String)
    }

    private let queue = DispatchQueue(
        label: "com.cmux.vnc-proxy.\(UUID().uuidString)",
        qos: .userInteractive
    )
    private var listener: NWListener?
    private var viewerConnection: NWConnection?
    private var remoteConnection: NWConnection?
    private var remoteHost: String = ""
    private var remotePort: UInt16 = 0
    private var eventHandler: ((Event) -> Void)?
    private var isStopping = false

    deinit {
        stop()
    }

    func start(
        remoteHost: String,
        remotePort: Int,
        eventHandler: @escaping (Event) -> Void
    ) throws {
        guard (1...65535).contains(remotePort) else {
            throw NSError(
                domain: "cmux.vnc.proxy",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "vnc.error.invalidRemotePort",
                        defaultValue: "Invalid remote VNC port."
                    )
                ]
            )
        }

        self.remoteHost = remoteHost
        self.remotePort = UInt16(remotePort)
        self.eventHandler = eventHandler
        isStopping = false

        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocketOptions, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let listenerPort = listener?.port?.rawValue else {
                    self.emit(
                        .failed(
                            String(
                                localized: "vnc.error.loopbackProxyPortUnavailable",
                                defaultValue: "VNC local proxy did not expose a loopback port."
                            )
                        )
                    )
                    return
                }
                self.emit(.listenerReady(port: listenerPort))
            case .failed(let error):
                self.emit(.failed(error.localizedDescription))
                self.stopLocked()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.attachViewerConnection(connection)
            }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        guard !isStopping else { return }
        isStopping = true

        listener?.cancel()
        listener = nil
        viewerConnection?.cancel()
        viewerConnection = nil
        remoteConnection?.cancel()
        remoteConnection = nil
    }

    private func attachViewerConnection(_ connection: NWConnection) {
        viewerConnection?.cancel()
        remoteConnection?.cancel()
        remoteConnection = nil
        viewerConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectRemote()
            case .failed(let error):
                self.emit(.failed(error.localizedDescription))
                self.stopLocked()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveViewerMessage()
    }

    private func connectRemote() {
        guard remoteConnection == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: remotePort) else {
            emit(
                .failed(
                    String(
                        localized: "vnc.error.invalidRemotePort",
                        defaultValue: "Invalid remote VNC port."
                    )
                )
            )
            stopLocked()
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let remoteParameters = NWParameters(tls: nil, tcp: tcpOptions)
        let remote = NWConnection(host: NWEndpoint.Host(remoteHost), port: nwPort, using: remoteParameters)
        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.remoteConnected)
            case .failed(let error):
                self.emit(.failed(error.localizedDescription))
                self.stopLocked()
            case .cancelled:
                self.emit(.remoteDisconnected)
            default:
                break
            }
        }
        remote.start(queue: queue)
        remoteConnection = remote
        receiveRemoteBytes()
    }

    private func receiveViewerMessage() {
        guard let viewerConnection else { return }
        viewerConnection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.emit(.failed(error.localizedDescription))
                self.stopLocked()
                return
            }

            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.emit(.remoteDisconnected)
                self.stopLocked()
                return
            }

            if let data, !data.isEmpty {
                self.remoteConnection?.send(content: data, completion: .contentProcessed { sendError in
                    guard let sendError else { return }
                    self.emit(.failed(sendError.localizedDescription))
                    self.stopLocked()
                })
            }

            self.receiveViewerMessage()
        }
    }

    private func receiveRemoteBytes() {
        guard let remoteConnection else { return }
        remoteConnection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.emit(.failed(error.localizedDescription))
                self.stopLocked()
                return
            }

            if let data, !data.isEmpty {
                self.sendBinaryToViewer(data)
            }

            if isComplete {
                self.emit(.remoteDisconnected)
                self.stopLocked()
                return
            }

            self.receiveRemoteBytes()
        }
    }

    private func sendBinaryToViewer(_ payload: Data) {
        guard let viewerConnection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        viewerConnection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.queue.async {
                    self.emit(.failed(error.localizedDescription))
                    self.stopLocked()
                }
            }
        })
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }
}

private final class VncPanelScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var panel: VncPanel?

    init(panel: VncPanel) {
        self.panel = panel
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        Task { @MainActor [weak panel] in
            panel?.handleViewerMessage(type: type, payload: payload)
        }
    }
}

private final class VncPanelNavigationDelegate: NSObject, WKNavigationDelegate {
    var didFinishNavigation: (() -> Void)?
    var didFailNavigation: ((String) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        _ = webView
        _ = navigation
        didFinishNavigation?()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = webView
        _ = navigation
        didFailNavigation?(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = webView
        _ = navigation
        didFailNavigation?(error.localizedDescription)
    }
}

@MainActor
private final class VncFakeSessionView: NSView {
    enum InputEvent {
        case keyDown(modified: Bool)
        case text(String)
        case mouseDown
        case mouseUp
        case mouseDragged
        case scroll
    }

    var onInputEvent: ((InputEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        _ = event
        return true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasNonShiftModifiers = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
        onInputEvent?(.keyDown(modified: hasNonShiftModifiers))
        if let characters = event.characters, !characters.isEmpty {
            onInputEvent?(.text(characters))
        }
        interpretKeyEvents([event])
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
        onInputEvent?(.mouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        onInputEvent?(.mouseUp)
    }

    override func mouseDragged(with event: NSEvent) {
        _ = event
        onInputEvent?(.mouseDragged)
    }

    override func scrollWheel(with event: NSEvent) {
        _ = event
        onInputEvent?(.scroll)
    }
}

@MainActor
final class VncNativeSessionHostView: NSView {
    private weak var sessionView: NSView?

    init(sessionView: NSView) {
        self.sessionView = sessionView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        sessionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionView)
        NSLayoutConstraint.activate([
            sessionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sessionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sessionView.topAnchor.constraint(equalTo: topAnchor),
            sessionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        _ = event
        return true
    }

    override func becomeFirstResponder() -> Bool {
        if focusSessionViewIfPossible() {
            return true
        }
        return super.becomeFirstResponder()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard let sessionView,
              !sessionView.isHidden,
              sessionView.alphaValue > 0 else {
            return super.hitTest(point)
        }
        let pointInSession = convert(point, to: sessionView)
        if let target = sessionView.hitTest(pointInSession) {
            return target
        }
        return sessionView.frame.contains(point) ? sessionView : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        _ = focusSessionViewIfPossible()
        if let sessionView {
            sessionView.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        _ = focusSessionViewIfPossible()
        if let sessionView {
            sessionView.rightMouseDown(with: event)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        _ = focusSessionViewIfPossible()
        if let sessionView {
            sessionView.otherMouseDown(with: event)
            return
        }
        super.otherMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let sessionView {
            sessionView.mouseDragged(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if let sessionView {
            sessionView.rightMouseDragged(with: event)
            return
        }
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if let sessionView {
            sessionView.otherMouseDragged(with: event)
            return
        }
        super.otherMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let sessionView {
            sessionView.mouseUp(with: event)
            return
        }
        super.mouseUp(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if let sessionView {
            sessionView.rightMouseUp(with: event)
            return
        }
        super.rightMouseUp(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if let sessionView {
            sessionView.otherMouseUp(with: event)
            return
        }
        super.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let sessionView {
            sessionView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        _ = focusSessionViewIfPossible()
        if let sessionView {
            sessionView.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if let sessionView {
            sessionView.keyUp(with: event)
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if let sessionView {
            sessionView.flagsChanged(with: event)
            return
        }
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        _ = focusSessionViewIfPossible()
        if let sessionView, sessionView.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @discardableResult
    func focusSessionViewIfPossible() -> Bool {
        guard let window, let sessionView else { return false }
        if window.firstResponder === sessionView {
            return true
        }
        return window.makeFirstResponder(sessionView)
    }
}

@MainActor
private final class VncNativeSessionController: NSObject {
    private struct PendingConnectRequest {
        let targetAddress: NSObject
        let options: NSObject?
    }

    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/ScreenSharing.framework",
        "/System/Library/PrivateFrameworks/ScreenSharingKit.framework",
    ]
    private static let sessionViewClassName = "SSSessionView"
    private static let connectionOptionsClassName = "SSConnectionOptions"
    private static let addressClassName = "SSAddress"
    private static let pollInterval: TimeInterval = 0.1
    private static let connectAttemptTimeout: TimeInterval = 6.0
    private static let preferredScreenQualityMode: Int = 0
    private static let preferredControlMode: Int = 1
    private static let minimumRemotePixelSize = CGSize(width: 960, height: 600)
    private static let maximumRemotePixelSize = CGSize(width: 3840, height: 2160)
    private static let fakeNativeUITestEnvKey = "CMUX_UI_TEST_VNC_FAKE_NATIVE"

    enum InputEvent {
        case keyDown(modified: Bool)
        case text(String)
        case mouseDown
        case mouseUp
        case mouseDragged
        case scroll
    }

    private static let attemptedFrameworkLoad: Bool = {
        for path in frameworkPaths {
            if let bundle = Bundle(path: path) {
                _ = try? bundle.loadAndReturnError()
            }
        }
        return true
    }()

    let hostView: VncNativeSessionHostView

    var onStateChange: ((VncPanelConnectionState, String?) -> Void)?
    var onInputEvent: ((InputEvent) -> Void)?

    private let sessionView: NSView
    private let sessionObject: NSObject
    private let usesFakeNativeSession: Bool
    private var pollTimer: Timer?
    private var emittedState: VncPanelConnectionState = .idle
    private var fakeState: VncPanelConnectionState = .idle
    private var pendingConnectAttempt = false
    private var attemptDeadline: Date?
    private var pendingConnectRequest: PendingConnectRequest?

    static func create() -> VncNativeSessionController? {
        if ProcessInfo.processInfo.environment[fakeNativeUITestEnvKey] == "1" {
            let sessionView = VncFakeSessionView(frame: .zero)
            return VncNativeSessionController(
                sessionView: sessionView,
                sessionObject: sessionView,
                usesFakeNativeSession: true
            )
        }

        _ = attemptedFrameworkLoad
        guard let sessionViewClass = NSClassFromString(sessionViewClassName) as? NSView.Type else {
            return nil
        }
        let sessionView = sessionViewClass.init(frame: .zero)
        let sessionObject = sessionView
        return VncNativeSessionController(
            sessionView: sessionView,
            sessionObject: sessionObject,
            usesFakeNativeSession: false
        )
    }

    private init(sessionView: NSView, sessionObject: NSObject, usesFakeNativeSession: Bool) {
        self.sessionView = sessionView
        self.sessionObject = sessionObject
        self.usesFakeNativeSession = usesFakeNativeSession

        let hostView = VncNativeSessionHostView(sessionView: sessionView)
        self.hostView = hostView

        super.init()

        configureSessionViewDefaults()
        startPollingState()

        if let fakeSessionView = sessionView as? VncFakeSessionView {
            fakeSessionView.onInputEvent = { [weak self] inputEvent in
                self?.handleFakeInputEvent(inputEvent)
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    func connect(targetHost: String, port: Int, username: String, password: String) {
        if usesFakeNativeSession {
            _ = targetHost
            _ = port
            _ = username
            _ = password
            pendingConnectRequest = nil
            pendingConnectAttempt = false
            attemptDeadline = nil
            fakeState = .connected
            emit(.connecting, detail: nil)
            emit(.connected, detail: nil)
            return
        }

        guard let targetAddress = Self.makeConnectionAddressObject(
            host: targetHost,
            port: port,
            username: username,
            password: password
        ) else {
            emit(.error, detail: nil)
            return
        }

        let options = makeConnectionOptions()
        pendingConnectRequest = PendingConnectRequest(targetAddress: targetAddress, options: options)
        pendingConnectAttempt = false
        attemptDeadline = nil
        emit(.connecting, detail: nil)
        beginPendingConnectIfPossible()
    }

    func disconnect(suppressUpdate: Bool = false) {
        pendingConnectRequest = nil
        pendingConnectAttempt = false
        attemptDeadline = nil

        if usesFakeNativeSession {
            fakeState = .disconnected
            if suppressUpdate {
                emittedState = .idle
                return
            }
            emit(.disconnected, detail: nil)
            return
        }

        if !invokeVoid(on: sessionObject, selectorName: "closeSession") {
            if !invokeVoid(on: sessionObject, selectorName: "disconnect") {
                _ = invokeVoid(on: sessionObject, selectorName: "cancelConnection")
            }
        }

        if suppressUpdate {
            emittedState = .idle
            return
        }

        emit(.disconnected, detail: nil)
    }

    func close() {
        disconnect(suppressUpdate: true)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func focus() {
        _ = hostView.focusSessionViewIfPossible()
        _ = invokeVoid(on: sessionObject, selectorName: "focus")
    }

    private func configureSessionViewDefaults() {
        // Fill mode can crop the desktop on aspect-ratio mismatch. Use fit-mode
        // scaling so remote top chrome (menu bar) stays visible.
        setBool(false, on: sessionObject, selectorName: "setFillsWindow:")
        setBool(true, on: sessionObject, selectorName: "setShouldScaleScreen:")
        setBool(true, on: sessionObject, selectorName: "setDynamicResolutionMode:")
        setBool(true, on: sessionObject, selectorName: "setSwitchToDynamicResolutionWhenReady:")
        setObjectBool(true, on: sessionObject, selectorName: "setControlCursor:")
        setObjectBool(true, on: sessionObject, selectorName: "setObserveCursor:")
        setObjectBool(true, on: sessionObject, selectorName: "setShowCursor:")
        setObjectBool(false, on: sessionObject, selectorName: "setHideCursor:")
        setObjectBool(false, on: sessionObject, selectorName: "setHilightCursor:")
        setBool(true, on: sessionObject, selectorName: "setViewerCursorVisible:")
        setBool(true, on: sessionObject, selectorName: "setShouldShowCursorForUnknownCursorState:")
        configureInteractiveControlMode()
        setBool(true, on: sessionObject, selectorName: "setShouldSharePasteboard:")
        setBool(true, on: sessionObject, selectorName: "setShouldAllowSendPasteboard:")
        setBool(false, on: sessionObject, selectorName: "setShouldSuppressFirstControlStateOverlay:")
        if boolValue(on: sessionObject, selectorName: "supportsChangingScreenQualityMode") {
            setInt(Self.preferredScreenQualityMode, on: sessionObject, selectorName: "setScreenQualityMode:")
        }
    }

    private func configureInteractiveControlMode() {
        setInt(Self.preferredControlMode, on: sessionObject, selectorName: "setControlMode:")
        setBool(true, on: sessionObject, selectorName: "setRequestedControl:")
        setBool(true, on: sessionObject, selectorName: "setSessionAllowsControl:")
        setBool(true, on: sessionObject, selectorName: "setKeyboardFocusEnabled:")
        setBool(true, on: sessionObject, selectorName: "_setKeyboardFocus:")
        _ = invokeVoid(on: sessionObject, selectorName: "configureInputEventConsumer")
    }

    private func makeConnectionOptions() -> NSObject? {
        guard let optionsClass = NSClassFromString(Self.connectionOptionsClassName) as? NSObject.Type else {
            return nil
        }

        let defaultSelector = NSSelectorFromString("defaultOptions")
        let optionsObject: NSObject
        if optionsClass.responds(to: defaultSelector),
           let unmanaged = optionsClass.perform(defaultSelector),
           let defaults = unmanaged.takeUnretainedValue() as? NSObject {
            optionsObject = defaults
        } else {
            optionsObject = optionsClass.init()
        }

        let preferredRemotePixelSize = preferredRemotePixelSize()
        setBool(true, on: optionsObject, selectorName: "setShouldScaleScreen:")
        setBool(true, on: optionsObject, selectorName: "setSkipAddressPresentation:")
        setBool(true, on: optionsObject, selectorName: "setShouldSkipAddressWindow:")
        setBool(true, on: optionsObject, selectorName: "setSkipUserPassDialogIfPossible:")
        setBool(false, on: optionsObject, selectorName: "setShowConnectionProgress:")
        setBool(false, on: optionsObject, selectorName: "setShouldReturnToAddressBox:")
        setBool(true, on: optionsObject, selectorName: "setNoReconnect:")
        setBool(false, on: optionsObject, selectorName: "setShouldFallbackToObserve:")
        setBool(true, on: optionsObject, selectorName: "setScreenQualitySet:")
        setInt(Self.preferredScreenQualityMode, on: optionsObject, selectorName: "setScreenQualityMode:")
        setSize(preferredRemotePixelSize, on: optionsObject, selectorName: "setMaxSize:")
        setSize(preferredRemotePixelSize, on: sessionObject, selectorName: "setDynamicResolutionMaxPixels:")
        return optionsObject
    }

    private static func makeConnectionAddress(
        host: String,
        port: Int,
        username: String,
        password: String
    ) -> String? {
        guard (1...65535).contains(port) else { return nil }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }

        let hostComponent = trimmedHost.contains(":")
            ? "[\(trimmedHost)]"
            : trimmedHost
        let usernameTrimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordTrimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let authComponent: String
        if usernameTrimmed.isEmpty {
            authComponent = ""
        } else {
            let encodedUser = Self.encodeUserInfo(usernameTrimmed)
            if passwordTrimmed.isEmpty {
                authComponent = "\(encodedUser)@"
            } else {
                let encodedPassword = Self.encodeUserInfo(passwordTrimmed)
                authComponent = "\(encodedUser):\(encodedPassword)@"
            }
        }

        return "vnc://\(authComponent)\(hostComponent):\(port)"
    }

    private static func makeConnectionAddressObject(
        host: String,
        port: Int,
        username: String,
        password: String
    ) -> NSObject? {
        guard let addressString = makeConnectionAddress(
            host: host,
            port: port,
            username: username,
            password: password
        ) else {
            return nil
        }

        guard let addressClass = NSClassFromString(addressClassName) as? NSObject.Type else {
            return nil
        }
        let selector = NSSelectorFromString("addressFromString:")
        guard addressClass.responds(to: selector),
              let unmanaged = addressClass.perform(selector, with: addressString as NSString),
              let addressObject = unmanaged.takeUnretainedValue() as? NSObject else {
            return nil
        }
        return addressObject
    }

    private static func encodeUserInfo(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func startPollingState() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectionState()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private func refreshConnectionState() {
        if usesFakeNativeSession {
            emit(fakeState, detail: nil)
            return
        }

        beginPendingConnectIfPossible()
        if pendingConnectRequest != nil {
            emit(.connecting, detail: nil)
            return
        }

        let isConnected = boolValue(on: sessionObject, selectorName: "isConnected")
        let isConnecting = boolValue(on: sessionObject, selectorName: "isConnecting")
        let isDisconnected =
            boolValue(on: sessionObject, selectorName: "isDisconnected") ||
            boolValue(on: sessionObject, selectorName: "isNotConnected")

        if isConnected {
            configureInteractiveControlMode()
            pendingConnectAttempt = false
            attemptDeadline = nil
            emit(.connected, detail: nil)
            return
        }

        if isConnecting {
            emit(.connecting, detail: nil)
            return
        }

        if pendingConnectAttempt,
           let attemptDeadline,
           Date() >= attemptDeadline {
            pendingConnectAttempt = false
            self.attemptDeadline = nil
            emit(.error, detail: nil)
            return
        }

        if pendingConnectAttempt {
            emit(.connecting, detail: nil)
            return
        }

        if isDisconnected {
            emit(.disconnected, detail: nil)
            return
        }

        emit(.idle, detail: nil)
    }

    private func beginPendingConnectIfPossible() {
        if usesFakeNativeSession { return }

        guard let request = pendingConnectRequest else { return }
        guard hostView.window != nil else { return }

        pendingConnectRequest = nil
        pendingConnectAttempt = true
        attemptDeadline = Date().addingTimeInterval(Self.connectAttemptTimeout)

        if invokeVoidObjectObject(
            on: sessionObject,
            selectorName: "connectToAddress:withOptions:",
            first: request.targetAddress,
            second: request.options
        ) {
            return
        }

        pendingConnectAttempt = false
        attemptDeadline = nil
        emit(.error, detail: nil)
    }

    private func emit(_ state: VncPanelConnectionState, detail: String?) {
        guard emittedState != state || detail != nil else { return }
        emittedState = state
        onStateChange?(state, detail)
    }

    private func handleFakeInputEvent(_ inputEvent: VncFakeSessionView.InputEvent) {
        let event: InputEvent
        switch inputEvent {
        case .keyDown(let modified):
            event = .keyDown(modified: modified)
        case .text(let text):
            event = .text(text)
        case .mouseDown:
            event = .mouseDown
        case .mouseUp:
            event = .mouseUp
        case .mouseDragged:
            event = .mouseDragged
        case .scroll:
            event = .scroll
        }
        onInputEvent?(event)
    }

    private func boolValue(on object: NSObject, selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return false
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(object, selector)
    }

    private func setBool(_ value: Bool, on object: NSObject, selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, value)
    }

    private func setObjectBool(_ value: Bool, on object: NSObject, selectorName: String) {
        setObject(NSNumber(value: value), on: object, selectorName: selectorName)
    }

    private func setObject(_ value: AnyObject?, on object: NSObject, selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, value)
    }

    private func setInt(_ value: Int, on object: NSObject, selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, value)
    }

    private func setSize(_ value: CGSize, on object: NSObject, selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, CGSize) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, value)
    }

    private func preferredRemotePixelSize() -> CGSize {
        let backingScale = max(hostView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0, 1.0)
        let bounds = hostView.bounds
        let pixelWidth = floor(bounds.width * backingScale)
        let pixelHeight = floor(bounds.height * backingScale)
        let width = min(
            Self.maximumRemotePixelSize.width,
            max(Self.minimumRemotePixelSize.width, pixelWidth)
        )
        let height = min(
            Self.maximumRemotePixelSize.height,
            max(Self.minimumRemotePixelSize.height, pixelHeight)
        )
        return CGSize(width: width, height: height)
    }

    @discardableResult
    private func invokeVoid(on object: NSObject, selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return false
        }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector)
        return true
    }

    @discardableResult
    private func invokeVoidObjectObject(
        on object: NSObject,
        selectorName: String,
        first: AnyObject?,
        second: AnyObject?
    ) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let implementation = object.method(for: selector) else {
            return false
        }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let function = unsafeBitCast(implementation, to: Function.self)
        function(object, selector, first, second)
        return true
    }
}

@MainActor
final class VncPanel: Panel, ObservableObject {
    private struct InputTelemetry {
        var keyDownCount: Int = 0
        var modifiedKeyDownCount: Int = 0
        var textInputCount: Int = 0
        var mouseDownCount: Int = 0
        var mouseUpCount: Int = 0
        var mouseDraggedCount: Int = 0
        var scrollCount: Int = 0
        var lastTextLength: Int = 0
        var lastTextContainsNonASCII: Bool = false
    }

    private static let scriptMessageHandlerName = "cmuxVncPanelState"

    let id: UUID
    let panelType: PanelType = .vnc
    private(set) var workspaceId: UUID

    @Published var endpointInput: String {
        didSet {
            refreshDisplayTitle()
        }
    }
    @Published var usernameInput: String {
        didSet {
            maybeSubmitCredentialsIfReady()
        }
    }
    @Published var passwordInput: String {
        didSet {
            maybeSubmitCredentialsIfReady()
        }
    }
    @Published private(set) var connectionState: VncPanelConnectionState = .idle {
        didSet {
            refreshDisplayTitle()
        }
    }
    @Published private(set) var displayTitle: String
    @Published private(set) var lastErrorDetail: String?
    @Published private(set) var requiredCredentialFields: Set<VncCredentialField> = []
    @Published private(set) var recentTargets: [String]
    @Published private(set) var discoveredTargets: [VncDiscoveredTarget] = []
    @Published private(set) var focusFlashToken: Int = 0
    @Published private(set) var endpointFocusRequestID: UUID = UUID()
    @Published private(set) var usernameFocusRequestID: UUID = UUID()
    @Published private(set) var passwordFocusRequestID: UUID = UUID()

    let webView: CmuxWebView?
    let nativeSessionHostView: NSView?

    var usesNativeRenderer: Bool {
        nativeSessionController != nil
    }

    var displayIcon: String? {
        isConnected ? "display.2" : "display"
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    var isAwaitingCredentials: Bool {
        !requiredCredentialFields.isEmpty
    }

    var requiredCredentialFieldNames: [String] {
        requiredCredentialFields.map(\.rawValue).sorted()
    }

    var activeEndpointDisplay: String? {
        activeTarget?.displayString
    }

    var endpointForAutomation: String? {
        if let activeTarget {
            return activeTarget.displayString
        }
        let trimmed = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var rendererBackendForAutomation: String {
        usesNativeRenderer ? "native" : "webview"
    }

    var viewerReadyForAutomation: Bool {
        usesNativeRenderer || isViewerReady
    }

    var viewerLoadingForAutomation: Bool {
        if usesNativeRenderer {
            return false
        }
        return webView?.isLoading ?? false
    }

    var viewerURLForAutomation: String? {
        if usesNativeRenderer {
            return nil
        }
        return webView?.url?.absoluteString
    }

    var proxyActiveForAutomation: Bool {
        if usesNativeRenderer {
            return false
        }
        return proxyBridge != nil
    }

    var inputKeyDownCountForAutomation: Int {
        inputTelemetry.keyDownCount
    }

    var inputModifiedKeyDownCountForAutomation: Int {
        inputTelemetry.modifiedKeyDownCount
    }

    var inputTextEventCountForAutomation: Int {
        inputTelemetry.textInputCount
    }

    var inputMouseDownCountForAutomation: Int {
        inputTelemetry.mouseDownCount
    }

    var inputMouseUpCountForAutomation: Int {
        inputTelemetry.mouseUpCount
    }

    var inputMouseDraggedCountForAutomation: Int {
        inputTelemetry.mouseDraggedCount
    }

    var inputScrollCountForAutomation: Int {
        inputTelemetry.scrollCount
    }

    var inputLastTextLengthForAutomation: Int {
        inputTelemetry.lastTextLength
    }

    var inputLastTextContainsNonASCIIForAutomation: Bool {
        inputTelemetry.lastTextContainsNonASCII
    }

    var activationWindow: NSWindow? {
        if let nativeSessionHostView {
            return nativeSessionHostView.window
        }
        return webView?.window
    }

    private var activeTarget: VncPanelTarget?
    private var proxyBridge: VncWebSocketProxyBridge?
    private var pendingViewerScripts: [String] = []
    private var isViewerReady: Bool = false
    private var messageHandler: VncPanelScriptMessageHandler?
    private var navigationDelegate: VncPanelNavigationDelegate?
    private var bonjourDiscovery: VncBonjourDiscovery?
    private var nativeSessionController: VncNativeSessionController?
    private var inputTelemetry = InputTelemetry()
    private var connectAttemptID = UUID()

    init(
        workspaceId: UUID,
        endpoint: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        let initialEndpoint = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.endpointInput = initialEndpoint
        self.usernameInput = ""
        self.passwordInput = ""
        self.recentTargets = VncRecentTargetsStore.load()
        self.displayTitle = initialEndpoint.isEmpty
            ? String(localized: "vnc.panel.defaultTitle", defaultValue: "VNC")
            : initialEndpoint

        let nativeSessionController = VncNativeSessionController.create()
        self.nativeSessionController = nativeSessionController
        self.nativeSessionHostView = nativeSessionController?.hostView

        if let nativeSessionController {
            self.webView = nil
            nativeSessionController.onStateChange = { [weak self] state, detail in
                self?.handleNativeSessionState(state, detail: detail)
            }
            nativeSessionController.onInputEvent = { [weak self] event in
                self?.recordNativeInputEvent(event)
            }
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

            let webView = CmuxWebView(frame: .zero, configuration: configuration)
            webView.underPageBackgroundColor = NSColor.black
            webView.allowsBackForwardNavigationGestures = false
            webView.allowsLinkPreview = false
            webView.setValue(false, forKey: "drawsBackground")
            self.webView = webView

            loadViewer()
        }

        startDiscovery()
        requestEndpointFieldFocus()
        refreshDisplayTitle()
    }

    deinit {
        proxyBridge?.stop()
        bonjourDiscovery?.stop()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func sessionSnapshot() -> SessionVncPanelSnapshot {
        SessionVncPanelSnapshot(
            endpointInput: endpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : endpointInput,
            usernameInput: usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : usernameInput,
            autoConnect: isConnected || connectionState == .connecting
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionVncPanelSnapshot) {
        if let endpointInput = snapshot.endpointInput?.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpointInput.isEmpty {
            self.endpointInput = endpointInput
        }
        if let usernameInput = snapshot.usernameInput?.trimmingCharacters(in: .whitespacesAndNewlines),
           !usernameInput.isEmpty {
            self.usernameInput = usernameInput
        }

        if snapshot.autoConnect {
            connect()
        }
    }

    func connect() {
        guard let target = VncPanelTarget.parse(endpointInput) else {
            setError(
                String(
                    localized: "vnc.error.invalidTarget",
                    defaultValue: "Enter a valid VNC target, for example 192.168.1.10:5900."
                )
            )
            requestEndpointFieldFocus()
            return
        }

        disconnectFromCurrentSession(notifyViewer: true)
        resetAutomationInputTelemetry()
        activeTarget = target
        connectionState = .connecting
        lastErrorDetail = nil
        requiredCredentialFields = []
        endpointInput = target.displayString
        refreshDisplayTitle()
        let attemptID = UUID()
        connectAttemptID = attemptID

        guard nativeSessionController != nil else {
            setError(
                String(
                    localized: "vnc.error.nativeRendererUnavailable",
                    defaultValue: "Native VNC is unavailable on this macOS build."
                )
            )
            return
        }

        let username = usernameInput
        let password = passwordInput
        Task { [weak self] in
            let resolvedHost = await VncSSHHostAliasResolver.resolve(host: target.host) ?? target.host
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.connectAttemptID == attemptID else { return }
                guard self.activeTarget == target else { return }
                self.startNativeConnection(
                    targetHost: resolvedHost,
                    port: target.port,
                    username: username,
                    password: password
                )
            }
        }
    }

    private func startNativeConnection(
        targetHost: String,
        port: Int,
        username: String,
        password: String
    ) {
        guard let nativeSessionController else {
            setError(
                String(
                    localized: "vnc.error.nativeRendererUnavailable",
                    defaultValue: "Native VNC is unavailable on this macOS build."
                )
            )
            return
        }
        nativeSessionController.connect(
            targetHost: targetHost,
            port: port,
            username: username,
            password: password
        )
    }

    func disconnect() {
        disconnectFromCurrentSession(notifyViewer: true)
        connectionState = .disconnected
        lastErrorDetail = nil
        requiredCredentialFields = []
    }

    func requestEndpointFieldFocus() {
        endpointFocusRequestID = UUID()
    }

    func requestPasswordFieldFocus() {
        passwordFocusRequestID = UUID()
    }

    func requestUsernameFieldFocus() {
        usernameFocusRequestID = UUID()
    }

    func chooseEndpointSuggestion(_ endpoint: String, connectImmediately: Bool = false) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        endpointInput = trimmed
        requestEndpointFieldFocus()
        if connectImmediately {
            connect()
        }
    }

    func submitCredentials() {
        if usesNativeRenderer {
            connect()
            return
        }
        setError(
            String(
                localized: "vnc.error.nativeRendererUnavailable",
                defaultValue: "Native VNC is unavailable on this macOS build."
            )
        )
    }

    func close() {
        disconnectFromCurrentSession(notifyViewer: true)
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.scriptMessageHandlerName)
        }
        bonjourDiscovery?.stop()
        bonjourDiscovery = nil
        messageHandler = nil
        nativeSessionController?.close()
        nativeSessionController = nil
    }

    func focus() {
        if let nativeSessionController, let nativeSessionHostView {
            nativeSessionController.focus()
            if let window = nativeSessionHostView.window,
               window.firstResponder == nil {
                _ = window.makeFirstResponder(nativeSessionHostView)
            }
            return
        }

        if let webView, let window = webView.window {
            if !window.makeFirstResponder(webView) {
                requestEndpointFieldFocus()
            }
            return
        }
        requestEndpointFieldFocus()
    }

    func unfocus() {
        // Keep VNC connection alive when unfocused.
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken &+= 1
    }

    private func refreshDisplayTitle() {
        if let activeTarget {
            displayTitle = activeTarget.displayString
            return
        }

        let trimmed = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        displayTitle = trimmed.isEmpty
            ? String(localized: "vnc.panel.defaultTitle", defaultValue: "VNC")
            : trimmed
    }

    private func startDiscovery() {
        let discovery = VncBonjourDiscovery()
        discovery.onTargetsChanged = { [weak self] targets in
            Task { @MainActor [weak self] in
                self?.discoveredTargets = targets
            }
        }
        discovery.start()
        bonjourDiscovery = discovery
    }

    private func refreshRecentTargets() {
        recentTargets = VncRecentTargetsStore.load()
    }

    private func recordRecentTarget(_ target: VncPanelTarget) {
        let endpoint = target.displayString
        VncRecentTargetsStore.record(endpoint)
        refreshRecentTargets()
    }

    private func credentialFields(from payload: [String: Any]) -> Set<VncCredentialField> {
        guard let rawTypes = payload["types"] as? [String] else {
            return [.password]
        }
        let fields = Set(rawTypes.compactMap { VncCredentialField(rawValue: $0.lowercased()) })
        return fields.isEmpty ? [.password] : fields
    }

    private func hasCredentialValue(for field: VncCredentialField) -> Bool {
        switch field {
        case .username:
            return !usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password:
            return !passwordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func maybeSubmitCredentialsIfReady() {
        if usesNativeRenderer { return }
        guard isAwaitingCredentials else { return }
        let missingRequired = requiredCredentialFields.contains { !hasCredentialValue(for: $0) }
        guard !missingRequired else { return }
        submitCredentials()
    }

    private func loadViewer() {
        isViewerReady = false
        pendingViewerScripts.removeAll(keepingCapacity: true)
        guard let webView else { return }
        webView.loadHTMLString(Self.viewerHTML, baseURL: URL(string: "http://127.0.0.1/"))
    }

    private func handleViewerReady() {
        guard !isViewerReady else { return }
        isViewerReady = true
        flushPendingViewerScripts()
    }

    private func evaluateViewerScript(_ script: String) {
        guard let webView else { return }
        if isViewerReady {
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, let error else { return }
                self.setError(Self.javaScriptErrorDetail(error))
            }
        } else {
            pendingViewerScripts.append(script)
        }
    }

    private func flushPendingViewerScripts() {
        guard isViewerReady, !pendingViewerScripts.isEmpty else { return }
        let scripts = pendingViewerScripts
        pendingViewerScripts.removeAll(keepingCapacity: true)
        for script in scripts {
            evaluateViewerScript(script)
        }
    }

    private func disconnectFromCurrentSession(notifyViewer: Bool) {
        connectAttemptID = UUID()
        nativeSessionController?.disconnect(suppressUpdate: true)

        proxyBridge?.stop()
        proxyBridge = nil
        activeTarget = nil
        requiredCredentialFields = []

        if notifyViewer && !usesNativeRenderer {
            evaluateViewerScript("window.cmuxVncDisconnect && window.cmuxVncDisconnect();")
        }
    }

    private func handleProxyEvent(_ event: VncWebSocketProxyBridge.Event) {
        switch event {
        case .listenerReady(let port):
            let websocketURL = "ws://127.0.0.1:\(port)"
            let usernameLiteral = Self.javaScriptStringLiteral(usernameInput)
            let passwordLiteral = Self.javaScriptStringLiteral(passwordInput)
            let websocketLiteral = Self.javaScriptStringLiteral(websocketURL)
            let runtimeUnavailableDetailLiteral = Self.javaScriptStringLiteral(
                String(
                    localized: "vnc.error.viewerRuntimeUnavailable",
                    defaultValue: "VNC viewer runtime unavailable."
                )
            )
            evaluateViewerScript(
                """
                (() => {
                  if (typeof window.cmuxVncConnect !== "function") {
                    throw new Error(\(runtimeUnavailableDetailLiteral));
                  }
                  window.cmuxVncConnect(\(websocketLiteral), \(usernameLiteral), \(passwordLiteral));
                  return true;
                })();
                """
            )
        case .remoteConnected:
            if connectionState != .connected {
                connectionState = .connecting
            }
        case .remoteDisconnected:
            if connectionState != .error {
                connectionState = .disconnected
            }
            proxyBridge = nil
        case .failed(let detail):
            setError(detail)
            proxyBridge = nil
        }
    }

    private func handleNativeSessionState(_ state: VncPanelConnectionState, detail: String?) {
        switch state {
        case .idle:
            if connectionState == .connecting || connectionState == .connected {
                connectionState = .idle
            }
        case .connecting:
            connectionState = .connecting
            lastErrorDetail = nil
            requiredCredentialFields = []
        case .connected:
            connectionState = .connected
            lastErrorDetail = nil
            requiredCredentialFields = []
            if let activeTarget {
                recordRecentTarget(activeTarget)
            }
        case .disconnected:
            if connectionState != .error {
                connectionState = .disconnected
            }
            requiredCredentialFields = []
        case .error:
            setError(detail ?? "")
        }
    }

    fileprivate func handleViewerMessage(type: String, payload: [String: Any]) {
        switch type {
        case "ready":
            handleViewerReady()
        case "state":
            guard let state = payload["state"] as? String else { return }
            switch state {
            case "connecting":
                connectionState = .connecting
                lastErrorDetail = nil
            case "connected":
                connectionState = .connected
                lastErrorDetail = nil
                requiredCredentialFields = []
                if let activeTarget {
                    recordRecentTarget(activeTarget)
                }
            case "disconnected":
                connectionState = .disconnected
                requiredCredentialFields = []
            case "error":
                let detail = (payload["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                setError(detail ?? "")
            default:
                break
            }
        case "credentialsRequired":
            requiredCredentialFields = credentialFields(from: payload)
            connectionState = .connecting
            if requiredCredentialFields.contains(.username),
               !hasCredentialValue(for: .username) {
                requestUsernameFieldFocus()
            } else if requiredCredentialFields.contains(.password),
                      !hasCredentialValue(for: .password) {
                requestPasswordFieldFocus()
            }
            maybeSubmitCredentialsIfReady()
        default:
            break
        }
    }

    private func setError(_ detail: String) {
        connectionState = .error
        requiredCredentialFields = []
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        lastErrorDetail = normalized.isEmpty ? nil : normalized
    }

    private func resetAutomationInputTelemetry() {
        inputTelemetry = InputTelemetry()
    }

    private func recordNativeInputEvent(_ event: VncNativeSessionController.InputEvent) {
        switch event {
        case .keyDown(let modified):
            inputTelemetry.keyDownCount += 1
            if modified {
                inputTelemetry.modifiedKeyDownCount += 1
            }
        case .text(let text):
            inputTelemetry.textInputCount += 1
            if !text.isEmpty {
                inputTelemetry.lastTextLength = text.count
                inputTelemetry.lastTextContainsNonASCII = text.unicodeScalars.contains { $0.value > 127 }
            }
        case .mouseDown:
            inputTelemetry.mouseDownCount += 1
        case .mouseUp:
            inputTelemetry.mouseUpCount += 1
        case .mouseDragged:
            inputTelemetry.mouseDraggedCount += 1
        case .scroll:
            inputTelemetry.scrollCount += 1
        }
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func javaScriptErrorDetail(_ error: Error) -> String {
        let fallback = error.localizedDescription
        let nsError = error as NSError
        let userInfo = nsError.userInfo

        let message = userInfo["WKJavaScriptExceptionMessage"] as? String
        let line = (userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber)?.intValue
            ?? userInfo["WKJavaScriptExceptionLineNumber"] as? Int
        let column = (userInfo["WKJavaScriptExceptionColumnNumber"] as? NSNumber)?.intValue
            ?? userInfo["WKJavaScriptExceptionColumnNumber"] as? Int
        let sourceURL = userInfo["WKJavaScriptExceptionSourceURL"] as? String

        guard message != nil || line != nil || column != nil || sourceURL != nil else {
            return fallback
        }

        var components: [String] = []
        if let message, !message.isEmpty {
            components.append(message)
        }
        if let line, let column {
            components.append("line \(line):\(column)")
        } else if let line {
            components.append("line \(line)")
        }
        if let sourceURL, !sourceURL.isEmpty {
            components.append(sourceURL)
        }

        let detail = components.joined(separator: " ")
        return detail.isEmpty ? fallback : detail
    }

    private static var viewerHTML: String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              background: #000;
              overflow: hidden;
            }
            #screen {
              width: 100%;
              height: 100%;
              background: #000;
              outline: none;
            }
          </style>
        </head>
        <body>
          <div id="screen" tabindex="0"></div>
        </body>
        </html>
        """
    }
}
