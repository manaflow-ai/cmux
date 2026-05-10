import AppKit
import Combine
import CMUXWorkstream
import Darwin
import Foundation
import OSLog
import Security

private let cmxHivePublisherLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "hive-publisher"
)

@MainActor
final class CmxHiveWorkspacePublisher {
    static let shared = CmxHiveWorkspacePublisher()

    private static let publishDebounce: TimeInterval = 0.5
    private static let heartbeatInterval: TimeInterval = 15
    private static let leaseDuration: TimeInterval = 45
    private static let bridgePairingTTL: TimeInterval = 110
    private static let bridgeRotationLeadTime: TimeInterval = 30

    private weak var appDelegate: AppDelegate?
    private var cancellables = Set<AnyCancellable>()
    private var tabManagerCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var workspaceActivityByID: [UUID: Date] = [:]
    private var publishWorkItem: DispatchWorkItem?
    private var publishTask: Task<Void, Never>?
    private var bridgeStartTask: Task<Void, Never>?
    private var bridgeHost: CmxEmbeddedIrohBridge?
    private var bridgeAttachTicket: CmxHiveAttachTicket?
    private var nativeBridgeAdapter: CmxNativeBridgeSocketAdapter?
    private let nodeEpoch = UUID().uuidString
    private let bootID = UUID().uuidString
    private let nodeStartedAt = Date()
    private let nodeIdentity: CmxHiveNodeIdentity

    private init() {
        nodeIdentity = (try? CmxHiveNodeIdentity.loadOrCreate()) ?? CmxHiveNodeIdentity.ephemeral()
    }

    func start(appDelegate: AppDelegate) {
        guard self.appDelegate == nil else { return }
        self.appDelegate = appDelegate

        NotificationCenter.default.publisher(for: .mainWindowContextsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshSubscriptions()
                    self?.schedulePublish()
                }
            }
            .store(in: &cancellables)

        AuthManager.shared.$isAuthenticated
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.schedulePublish() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.schedulePublish() }
            }
            .store(in: &cancellables)

        Timer.publish(every: Self.heartbeatInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.schedulePublish() }
            }
            .store(in: &cancellables)

        refreshSubscriptions()
        schedulePublish()
    }

    func stop() {
        bridgeStartTask?.cancel()
        bridgeStartTask = nil
        bridgeHost?.stop()
        bridgeHost = nil
        bridgeAttachTicket = nil
        nativeBridgeAdapter?.stop()
        nativeBridgeAdapter = nil
    }

    func schedulePublish() {
        ensureBridgeTicketIfNeeded()
        publishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.publishCurrentSnapshot()
            }
        }
        publishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDebounce, execute: workItem)
    }

    private func refreshSubscriptions() {
        guard let appDelegate else { return }

        let liveManagers = appDelegate.mainWindowContexts.values.map(\.tabManager)
        let liveManagerIDs = Set(liveManagers.map(ObjectIdentifier.init))
        for key in tabManagerCancellables.keys where !liveManagerIDs.contains(key) {
            tabManagerCancellables[key]?.cancel()
            tabManagerCancellables.removeValue(forKey: key)
        }

        for manager in liveManagers {
            let key = ObjectIdentifier(manager)
            if tabManagerCancellables[key] == nil {
                tabManagerCancellables[key] = Publishers.Merge(
                    manager.$tabs.map { _ in () },
                    manager.$selectedTabId.map { _ in () }
                )
                .sink { [weak self] in
                    Task { @MainActor in
                        self?.markSelectedWorkspaceActivity(in: manager)
                        self?.refreshSubscriptions()
                        self?.schedulePublish()
                    }
                }
            }
            markSelectedWorkspaceActivity(in: manager)
        }

        let liveWorkspaces = liveManagers.flatMap(\.tabs)
        let liveWorkspaceIDs = Set(liveWorkspaces.map(\.id))
        for key in workspaceCancellables.keys where !liveWorkspaceIDs.contains(key) {
            workspaceCancellables[key]?.cancel()
            workspaceCancellables.removeValue(forKey: key)
            workspaceActivityByID.removeValue(forKey: key)
        }

        for (index, workspace) in liveWorkspaces.enumerated() {
            if workspaceActivityByID[workspace.id] == nil {
                workspaceActivityByID[workspace.id] = Date().addingTimeInterval(-Double(index))
            }
            if workspaceCancellables[workspace.id] == nil {
                workspaceCancellables[workspace.id] = workspace.objectWillChange
                    .sink { [weak self, weak workspace] _ in
                        Task { @MainActor in
                            guard let workspace else { return }
                            self?.workspaceActivityByID[workspace.id] = Date()
                            self?.schedulePublish()
                        }
                    }
            }
        }
    }

    private func markSelectedWorkspaceActivity(in manager: TabManager) {
        guard let selectedTabId = manager.selectedTabId else { return }
        workspaceActivityByID[selectedTabId] = Date()
    }

    private func publishCurrentSnapshot() {
        publishTask?.cancel()
        guard let payload = makeNodePayload() else { return }
        publishTask = Task {
            do {
                try await Self.publish(payload)
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                cmuxDebugLog("hive.publish.failed error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func ensureBridgeTicketIfNeeded(now: Date = Date()) {
        guard !Self.hasExternalAttachTicketConfig() else { return }
        guard AuthManager.shared.isAuthenticated else { return }
        guard let appDelegate, !appDelegate.mainWindowContexts.isEmpty else { return }
        guard bridgeStartTask == nil else { return }
        if let bridgeAttachTicket,
           bridgeAttachTicket.isUsable(at: now, leadTime: Self.bridgeRotationLeadTime),
           bridgeHost?.isRunning == true {
            return
        }
        let cmxSocketPath: String
        if let overridePath = Self.hiveCmxSocketPath() {
            cmxSocketPath = overridePath
        } else {
            do {
                let adapter = nativeBridgeAdapter ?? CmxNativeBridgeSocketAdapter(
                    appDelegate: appDelegate,
                    nodeID: nodeIdentity.nodeID
                )
                try adapter.startIfNeeded()
                nativeBridgeAdapter = adapter
                cmxSocketPath = adapter.socketPath
            } catch {
#if DEBUG
                cmuxDebugLog("hive.nativeBridge.failed error=\(error.localizedDescription)")
#endif
                return
            }
        }

        let previousBridgeHost = bridgeHost
        bridgeAttachTicket = nil

        let expiresAtUnix = UInt64(now.addingTimeInterval(Self.bridgePairingTTL).timeIntervalSince1970.rounded(.down))
        let context = CmxHiveBridgeStartContext(
            socketPath: cmxSocketPath,
            pairingID: "pairing_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            pairingSecret: Self.randomURLSafeToken(),
            expiresAtUnix: expiresAtUnix,
            rivetEndpoint: AuthEnvironment.hiveAPIBaseURL.absoluteString,
            stackProjectID: AuthEnvironment.stackProjectID,
            nodeID: nodeIdentity.nodeID,
            nodeName: Self.nodeDisplayName(),
            nodeSubtitle: "\(Self.nodePlatformLabel()) \(ProcessInfo.processInfo.machineHardwareName)",
            nodeKind: "macos",
            teamID: HiveWorkspaceTeamPreference.selectedTeamID()
        )

        bridgeStartTask = Task { [weak self] in
            do {
                let bridge = try await Self.startHiveBridge(context: context)
                await MainActor.run {
                    self?.bridgeHost = bridge.host
                    self?.bridgeAttachTicket = bridge.attachTicket
                    self?.bridgeStartTask = nil
                    previousBridgeHost?.retire()
                    cmxHivePublisherLogger.info("embedded iroh host started")
                    self?.schedulePublish()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.bridgeStartTask = nil
                }
            } catch {
                cmxHivePublisherLogger.error("embedded iroh host failed: \(error.localizedDescription, privacy: .public)")
#if DEBUG
                cmuxDebugLog("hive.bridge.failed error=\(error.localizedDescription)")
#endif
                await MainActor.run {
                    self?.bridgeStartTask = nil
                }
            }
        }
    }

    private func makeNodePayload(now: Date = Date()) -> CmxHiveNodePublishPayload? {
        guard AuthManager.shared.isAuthenticated else { return nil }
        guard let appDelegate else { return nil }
        let contexts = Array(appDelegate.mainWindowContexts.values)
        guard !contexts.isEmpty else { return nil }

        let workspaces = contexts
            .flatMap { context in
                context.tabManager.tabs.enumerated().map { index, workspace in
                    makeWorkspacePayload(workspace: workspace, index: index)
                }
            }
            .sorted { lhs, rhs in
                if lhs.lastActivityUnix != rhs.lastActivityUnix {
                    return lhs.lastActivityUnix > rhs.lastActivityUnix
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        let restore = appDelegate.hiveRestoreStateForPublisher()
        let attachTicket = Self.hiveAttachTicket()
            ?? bridgeAttachTicket?.usableTicket(at: now, leadTime: Self.bridgeRotationLeadTime)

        return CmxHiveNodePublishPayload(
            id: nodeIdentity.nodeID,
            machineGroupID: nodeIdentity.machineGroupID,
            nodeEpoch: nodeEpoch,
            bootID: bootID,
            nodeStartedAtUnix: nodeStartedAt.timeIntervalSince1970,
            name: Self.nodeDisplayName(),
            subtitle: "\(Self.nodePlatformLabel()) \(ProcessInfo.processInfo.machineHardwareName)",
            kind: "macos",
            isOnline: true,
            leaseExpiresAtUnix: now.addingTimeInterval(Self.leaseDuration).timeIntervalSince1970,
            restoreState: restore.restoreState,
            snapshotMode: restore.snapshotMode,
            attachTicket: attachTicket?.ticket,
            attachTicketExpiresAtUnix: attachTicket?.expiresAtUnix,
            workspaces: workspaces
        )
    }

    private func makeWorkspacePayload(workspace: Workspace, index: Int) -> CmxHiveWorkspacePublishPayload {
        let localID = workspace.id.uuidString
        let activityDate = workspaceActivityByID[workspace.id] ?? Date().addingTimeInterval(-Double(index))
        let terminals = workspace.panels.values
            .filter { $0.panelType == .terminal }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
            .map { panel in
                CmxHiveTerminalPublishPayload(
                    id: panel.id.uuidString,
                    title: panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        ?? String(localized: "commandPalette.kind.terminal", defaultValue: "Terminal"),
                    cols: 80,
                    rows: 24,
                    outputRows: []
                )
            }
        let space = CmxHiveSpacePublishPayload(
            id: "\(localID):main",
            title: String(localized: "hive.workspace.mainSpace", defaultValue: "main"),
            terminals: terminals
        )
        return CmxHiveWorkspacePublishPayload(
            id: localID,
            nodeID: nodeIdentity.nodeID,
            workspaceKey: "\(nodeIdentity.nodeID):\(localID)",
            localWorkspaceID: localID,
            title: workspace.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? String(localized: "workspace.placeholder.title", defaultValue: "Workspace"),
            preview: workspace.customDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            lastActivityUnix: activityDate.timeIntervalSince1970,
            unread: false,
            pinned: workspace.isPinned,
            spaces: [space]
        )
    }

    private nonisolated static func publish(_ payload: CmxHiveNodePublishPayload) async throws {
        let tokens = try await AuthManager.shared.currentTokens()
        guard var components = URLComponents(url: AuthEnvironment.hiveAPIBaseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/api/hive/nodes"
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID = HiveWorkspaceTeamPreference.selectedTeamID() {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CmxHiveWorkspacePublisherError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private nonisolated static func startHiveBridge(
        context: CmxHiveBridgeStartContext
    ) async throws -> CmxHiveStartedBridge {
        try await upsertBridgePairing(context)
        let host = try await CmxEmbeddedIrohBridge.start(context: context)
        return CmxHiveStartedBridge(
            host: host,
            attachTicket: CmxHiveAttachTicket(ticket: host.ticket, expiresAtUnix: context.expiresAtUnix)
        )
    }

    private nonisolated static func upsertBridgePairing(_ context: CmxHiveBridgeStartContext) async throws {
        let tokens = try await AuthManager.shared.currentTokens()
        guard var components = URLComponents(url: AuthEnvironment.hiveAPIBaseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/api/hive/pairings"
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID = context.teamID {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pairing_id": context.pairingID,
            "pairing_secret": context.pairingSecret,
            "expires_at_unix": context.expiresAtUnix,
            "node_id": context.nodeID,
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw CmxHiveWorkspacePublisherError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private nonisolated static func randomURLSafeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func nodeDisplayName() -> String {
        Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? String(localized: "node.connected.name", defaultValue: "cmx node")
    }

    private static func nodePlatformLabel() -> String {
        String(localized: "hive.node.platform.macos", defaultValue: "macOS")
    }

    private static func hiveAttachTicket() -> CmxHiveAttachTicket? {
        let environment = ProcessInfo.processInfo.environment
        let rawTicket = normalizedNonEmpty(environment["CMUX_HIVE_ATTACH_TICKET"])
            ?? attachTicketFromFile(environment["CMUX_HIVE_ATTACH_TICKET_FILE"])
        guard let ticket = rawTicket else { return nil }
        return CmxHiveAttachTicket(
            ticket: ticket,
            expiresAtUnix: attachTicketExpiresAtUnix(in: ticket)
        )
    }

    private static func hasExternalAttachTicketConfig() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return normalizedNonEmpty(environment["CMUX_HIVE_ATTACH_TICKET"]) != nil
            || normalizedNonEmpty(environment["CMUX_HIVE_ATTACH_TICKET_FILE"]) != nil
    }

    private static func hiveCmxSocketPath() -> String? {
        normalizedNonEmpty(ProcessInfo.processInfo.environment["CMUX_HIVE_CMX_SOCKET_PATH"])
    }

    private static func attachTicketFromFile(_ rawPath: String?) -> String? {
        guard let path = normalizedNonEmpty(rawPath),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        if let jsonLine = contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .compactMap(normalizedNonEmpty)
            .first(where: { $0.hasPrefix("{") }) {
            return jsonLine
        }
        return normalizedNonEmpty(contents)
    }

    private static func attachTicketExpiresAtUnix(in ticket: String) -> UInt64? {
        guard let data = ticket.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["auth"] as? [String: Any] else {
            return nil
        }
        if let expiresAtUnix = auth["expires_at_unix"] as? UInt64 {
            return expiresAtUnix
        }
        if let expiresAtUnix = auth["expires_at_unix"] as? NSNumber, expiresAtUnix.uint64Value > 0 {
            return expiresAtUnix.uint64Value
        }
        if let expiresAtUnix = auth["expires_at_unix"] as? Int, expiresAtUnix > 0 {
            return UInt64(expiresAtUnix)
        }
        if let expiresAtUnix = auth["expires_at_unix"] as? Double, expiresAtUnix > 0 {
            return UInt64(expiresAtUnix)
        }
        return nil
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CmxHiveWorkspacePublisherError: LocalizedError {
    case badStatus(Int)
    case embeddedBridgeStartFailed(String)
    case bridgeTicketMissing

    var errorDescription: String? {
        switch self {
        case .badStatus(let status):
            "Hive publish failed (\(status))."
        case .embeddedBridgeStartFailed(let message):
            "Embedded cmux iroh bridge failed to start: \(message)"
        case .bridgeTicketMissing:
            "cmux iroh bridge did not print an attach ticket."
        }
    }
}

private struct CmxHiveAttachTicket {
    let ticket: String
    let expiresAtUnix: UInt64?

    func isUsable(at date: Date, leadTime: TimeInterval) -> Bool {
        guard let expiresAtUnix else { return true }
        return TimeInterval(expiresAtUnix) > date.addingTimeInterval(leadTime).timeIntervalSince1970
    }

    func usableTicket(at date: Date, leadTime: TimeInterval) -> CmxHiveAttachTicket? {
        isUsable(at: date, leadTime: leadTime) ? self : nil
    }
}

struct CmxHiveBridgeStartContext: Sendable {
    let socketPath: String
    let pairingID: String
    let pairingSecret: String
    let expiresAtUnix: UInt64
    let rivetEndpoint: String
    let stackProjectID: String
    let nodeID: String
    let nodeName: String
    let nodeSubtitle: String
    let nodeKind: String
    let teamID: String?
}

private struct CmxHiveStartedBridge {
    let host: CmxEmbeddedIrohBridge
    let attachTicket: CmxHiveAttachTicket
}

private final class CmxNativeBridgeSocketAdapter {
    private static let maximumFrameBytes = 64 * 1024 * 1024
    private static let pollIntervalMilliseconds: Int32 = 1_000
    private static let replayInterval: TimeInterval = 1
    weak var appDelegate: AppDelegate?
    let nodeID: String
    let socketPath: String
    private let terminalController: TerminalController
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.cmux.hive.native-bridge.accept")
    private var serverSocket: Int32 = -1
    private var running = false

    @MainActor init(appDelegate: AppDelegate, nodeID: String) {
        self.appDelegate = appDelegate
        self.nodeID = nodeID
        terminalController = TerminalController.shared
        let bundle = Bundle.main.bundleIdentifier ?? "cmux"
        let key = "\(bundle):\(nodeID)"
        socketPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-hive-\(Self.stableID(for: key)).sock")
            .path
    }

    deinit {
        stop()
    }

    func startIfNeeded() throws {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CmxNativeBridgeSocketError.posix("socket", errno)
        }

        do {
            try Self.bind(socket: fd, path: socketPath)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            guard listen(fd, 64) == 0 else {
                throw CmxNativeBridgeSocketError.posix("listen", errno)
            }
        } catch {
            close(fd)
            throw error
        }

        stateLock.lock()
        if running {
            stateLock.unlock()
            close(fd)
            return
        }
        serverSocket = fd
        running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listener: fd)
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        let socketToClose = serverSocket
        serverSocket = -1
        stateLock.unlock()
        if socketToClose >= 0 {
            shutdown(socketToClose, SHUT_RDWR)
            close(socketToClose)
        }
        unlink(socketPath)
    }

    private var isRunning: Bool {
        stateLock.lock()
        let value = running
        stateLock.unlock()
        return value
    }

    private func acceptLoop(listener: Int32) {
        while isRunning {
            let client = accept(listener, nil, nil)
            if client < 0 {
                let code = errno
                if !isRunning || code == EBADF || code == EINVAL {
                    break
                }
                if code == EINTR {
                    continue
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                self?.handleClient(socket: client)
            }
        }
    }

    private func handleClient(socket: Int32) {
        defer { close(socket) }
        var state = CmxNativeBridgeClientState()

        do {
            while isRunning {
                var pollDescriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, Self.pollIntervalMilliseconds)
                if pollResult < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw CmxNativeBridgeSocketError.posix("poll", errno)
                }

                if pollResult > 0 {
                    guard let payload = try Self.readFrame(from: socket) else { break }
                    let message = try CmxNativeBridgeProtocol.decodeClientMessage(payload)
                    if try handle(message: message, state: &state, socket: socket) {
                        break
                    }
                }

                if Date() >= state.nextReplayAt {
                    try replayVisibleTerminalsIfChanged(state: &state, socket: socket, force: false)
                    state.nextReplayAt = Date().addingTimeInterval(Self.replayInterval)
                }
            }
        } catch {
            let payload = CmxNativeBridgeProtocol.encodeError(error.localizedDescription)
            try? Self.writeFrame(payload, to: socket)
        }
    }

    @discardableResult
    private func handle(
        message: CmxNativeBridgeClientMessage,
        state: inout CmxNativeBridgeClientState,
        socket: Int32
    ) throws -> Bool {
        switch message {
        case .helloNative, .hello:
            let snapshot = currentSnapshot(activeWorkspaceIndex: state.activeWorkspaceIndex)
            state.activeWorkspaceIndex = snapshot.activeWorkspaceIndex
            try Self.writeFrame(
                CmxNativeBridgeProtocol.encodeWelcome(sessionID: state.sessionID),
                to: socket
            )
            try Self.writeFrame(
                CmxNativeBridgeProtocol.encodeNativeSnapshot(snapshot),
                to: socket
            )
            state.nextReplayAt = Date()
        case .nativeLayout(let terminals):
            state.visibleTerminals = Dictionary(uniqueKeysWithValues: terminals.map { ($0.tabID, $0) })
            try replayVisibleTerminalsIfChanged(state: &state, socket: socket, force: true)
            state.nextReplayAt = Date().addingTimeInterval(Self.replayInterval)
        case .requestPtyReplay(let tabID):
            try replayTerminal(tabID, state: &state, socket: socket, force: true)
        case .nativeInput(let tabID, let data):
            sendInput(data, to: tabID)
            state.lastReplayTextByTerminalID.removeValue(forKey: tabID)
            state.nextReplayAt = Date().addingTimeInterval(0.08)
        case .command(let id, let command):
            switch command {
            case .selectWorkspace(let index):
                state.activeWorkspaceIndex = max(0, index)
                state.lastReplayTextByTerminalID.removeAll()
                try Self.writeFrame(CmxNativeBridgeProtocol.encodeCommandReply(id: id), to: socket)
                try Self.writeFrame(
                    CmxNativeBridgeProtocol.encodeNativeSnapshot(
                        currentSnapshot(activeWorkspaceIndex: state.activeWorkspaceIndex)
                    ),
                    to: socket
                )
            case .selectTabInPanel, .setWorkspacePinned, .setWorkspaceUnread, .other:
                try Self.writeFrame(CmxNativeBridgeProtocol.encodeCommandReply(id: id), to: socket)
            }
        case .ping:
            try Self.writeFrame(CmxNativeBridgeProtocol.encodePong(), to: socket)
        case .clientLatency:
            break
        case .detach:
            try Self.writeFrame(CmxNativeBridgeProtocol.encodeBye(), to: socket)
            return true
        }
        return false
    }

    private func replayVisibleTerminalsIfChanged(
        state: inout CmxNativeBridgeClientState,
        socket: Int32,
        force: Bool
    ) throws {
        let terminalIDs = state.visibleTerminals.keys.sorted()
        for terminalID in terminalIDs {
            try replayTerminal(terminalID, state: &state, socket: socket, force: force)
        }
    }

    private func replayTerminal(
        _ terminalID: UInt64,
        state: inout CmxNativeBridgeClientState,
        socket: Int32,
        force: Bool
    ) throws {
        let lineLimit = state.visibleTerminals[terminalID].map { max(Int($0.rows), 1) }
        guard let text = terminalText(for: terminalID, lineLimit: lineLimit) else { return }
        guard force || state.lastReplayTextByTerminalID[terminalID] != text else { return }
        state.lastReplayTextByTerminalID[terminalID] = text
        let normalized = text.replacingOccurrences(of: "\n", with: "\r\n")
        let payload = Data(("\u{001B}[2J\u{001B}[H" + normalized).utf8)
        try Self.writeFrame(CmxNativeBridgeProtocol.encodePtyBytes(tabID: terminalID, data: payload), to: socket)
    }

    private func sendInput(_ data: Data, to terminalID: UInt64) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        _ = terminalController.v2MainSync {
            guard let terminalPanel = self.terminalPanel(for: terminalID) else { return false }
            terminalPanel.sendInput(text)
            return true
        }
    }

    private func terminalText(for terminalID: UInt64, lineLimit: Int?) -> String? {
        terminalController.v2MainSync {
            guard let terminalPanel = self.terminalPanel(for: terminalID) else { return nil }
            return self.terminalController.readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                includeScrollback: false,
                lineLimit: lineLimit
            )
        }
    }

    @MainActor
    private func terminalPanel(for nativeTerminalID: UInt64) -> TerminalPanel? {
        guard let appDelegate else { return nil }
        for workspace in orderedWorkspaces(appDelegate: appDelegate) {
            for terminalPanel in orderedTerminalPanels(in: workspace)
                where terminalID(workspaceID: workspace.id, panelID: terminalPanel.id) == nativeTerminalID {
                return terminalPanel
            }
        }
        return nil
    }

    private func currentSnapshot(activeWorkspaceIndex requestedIndex: Int) -> CmxNativeBridgeSnapshot {
        terminalController.v2MainSync {
            guard let appDelegate = self.appDelegate else {
                return CmxNativeBridgeSnapshot.empty
            }
            let workspaces = self.orderedWorkspaces(appDelegate: appDelegate)
            guard !workspaces.isEmpty else {
                return CmxNativeBridgeSnapshot.empty
            }

            let activeIndex = min(max(0, requestedIndex), workspaces.count - 1)
            let activeWorkspace = workspaces[activeIndex]
            let terminals = self.orderedTerminalPanels(in: activeWorkspace)
            let activeTerminalIndex = self.activeTerminalIndex(in: activeWorkspace, terminals: terminals)
            let activeTerminalID = terminals.indices.contains(activeTerminalIndex)
                ? self.terminalID(workspaceID: activeWorkspace.id, panelID: terminals[activeTerminalIndex].id)
                : 0
            let activeWorkspaceID = self.workspaceID(activeWorkspace.id)
            let activeSpaceID = self.spaceID(workspaceID: activeWorkspace.id)
            let panelID = self.panelID(workspaceID: activeWorkspace.id)

            return CmxNativeBridgeSnapshot(
                workspaces: workspaces.enumerated().map { _, workspace in
                    let terminalCount = self.orderedTerminalPanels(in: workspace).count
                    return [
                        "id": self.workspaceID(workspace.id),
                        "title": workspace.title,
                        "space_count": 1,
                        "tab_count": terminalCount,
                        "terminal_count": terminalCount,
                        "pinned": workspace.isPinned,
                        "has_activity": false,
                        "bell_count": UInt64(0),
                        "color": workspace.customColor ?? NSNull(),
                    ] as [String: Any]
                },
                activeWorkspaceIndex: activeIndex,
                activeWorkspaceID: activeWorkspaceID,
                spaces: [
                    [
                        "id": activeSpaceID,
                        "title": "main",
                        "pane_count": terminals.isEmpty ? 0 : 1,
                        "terminal_count": terminals.count,
                    ] as [String: Any],
                ],
                activeSpaceIndex: 0,
                activeSpaceID: activeSpaceID,
                panels: [
                    "kind": "leaf",
                    "panel_id": panelID,
                    "tabs": terminals.map { panel in
                        [
                            "id": self.terminalID(workspaceID: activeWorkspace.id, panelID: panel.id),
                            "title": panel.displayTitle,
                            "has_activity": false,
                            "bell_count": UInt64(0),
                        ] as [String: Any]
                    },
                    "active": activeTerminalIndex,
                    "active_tab_id": activeTerminalID,
                ] as [String: Any],
                focusedPanelID: panelID,
                focusedTabID: activeTerminalID,
                attachedClients: []
            )
        }
    }

    @MainActor
    private func orderedWorkspaces(appDelegate: AppDelegate) -> [Workspace] {
        appDelegate.mainWindowContexts
            .values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .flatMap(\.tabManager.tabs)
    }

    @MainActor
    private func orderedTerminalPanels(in workspace: Workspace) -> [TerminalPanel] {
        workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted {
                if $0.displayTitle != $1.displayTitle {
                    return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    @MainActor
    private func activeTerminalIndex(in workspace: Workspace, terminals: [TerminalPanel]) -> Int {
        if let focused = workspace.focusedPanelId,
           let index = terminals.firstIndex(where: { $0.id == focused }) {
            return index
        }
        return terminals.isEmpty ? 0 : 0
    }

    private func workspaceID(_ workspaceID: UUID) -> UInt64 {
        Self.stableID(for: "\(nodeID):\(workspaceID.uuidString)")
    }

    private func spaceID(workspaceID: UUID) -> UInt64 {
        Self.stableID(for: "\(nodeID):\(workspaceID.uuidString):space:main")
    }

    private func panelID(workspaceID: UUID) -> UInt64 {
        Self.stableID(for: "\(nodeID):\(workspaceID.uuidString):panel:main")
    }

    private func terminalID(workspaceID: UUID, panelID: UUID) -> UInt64 {
        Self.stableID(for: "\(nodeID):\(workspaceID.uuidString):terminal:\(panelID.uuidString)")
    }

    static func stableID(for value: String) -> UInt64 {
        let bytes = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "cmx-node"
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash == 0 ? 1 : hash
    }

    private static func bind(socket fd: Int32, path: String) throws {
        let parentURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if unlink(path) != 0, errno != ENOENT {
            throw CmxNativeBridgeSocketError.posix("unlink", errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        var didFit = false
        path.withCString { source in
            let sourceLength = strlen(source)
            guard sourceLength < maxLength else { return }
            _ = withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maxLength - 1)
            }
            didFit = true
        }
        guard didFit else {
            throw CmxNativeBridgeSocketError.pathTooLong(path)
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw CmxNativeBridgeSocketError.posix("bind", errno)
        }
        chmod(path, 0o600)
    }

    private static func readFrame(from socket: Int32) throws -> Data? {
        guard let header = try readExactly(4, from: socket) else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maximumFrameBytes else {
            throw CmxNativeBridgeSocketError.frameTooLarge
        }
        return try readExactly(Int(length), from: socket)
    }

    private static func readExactly(_ count: Int, from socket: Int32) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let bytesRead = data.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(socket, baseAddress.advanced(by: offset), count - offset)
            }
            if bytesRead > 0 {
                offset += bytesRead
                continue
            }
            if bytesRead == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            throw CmxNativeBridgeSocketError.posix("read", errno)
        }
        return data
    }

    private static func writeFrame(_ payload: Data, to socket: Int32) throws {
        guard payload.count <= maximumFrameBytes else {
            throw CmxNativeBridgeSocketError.frameTooLarge
        }
        var framed = Data()
        let length = UInt32(payload.count)
        framed.append(UInt8((length >> 24) & 0xFF))
        framed.append(UInt8((length >> 16) & 0xFF))
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(payload)
        var offset = 0
        while offset < framed.count {
            let written = framed.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return write(socket, baseAddress.advanced(by: offset), framed.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 || errno == EPIPE || errno == ECONNRESET {
                throw CmxNativeBridgeSocketError.closed
            }
            if errno == EINTR {
                continue
            }
            throw CmxNativeBridgeSocketError.posix("write", errno)
        }
    }
}

private struct CmxNativeBridgeClientState {
    let sessionID = UUID().uuidString
    var activeWorkspaceIndex = 0
    var visibleTerminals: [UInt64: CmxNativeBridgeTerminalViewport] = [:]
    var lastReplayTextByTerminalID: [UInt64: String] = [:]
    var nextReplayAt = Date()
}

private struct CmxNativeBridgeTerminalViewport {
    let tabID: UInt64
    let cols: UInt16
    let rows: UInt16
}

private struct CmxNativeBridgeSnapshot {
    let workspaces: [[String: Any]]
    let activeWorkspaceIndex: Int
    let activeWorkspaceID: UInt64
    let spaces: [[String: Any]]
    let activeSpaceIndex: Int
    let activeSpaceID: UInt64
    let panels: [String: Any]
    let focusedPanelID: UInt64
    let focusedTabID: UInt64
    let attachedClients: [[String: Any]]

    static let empty = CmxNativeBridgeSnapshot(
        workspaces: [],
        activeWorkspaceIndex: 0,
        activeWorkspaceID: 0,
        spaces: [],
        activeSpaceIndex: 0,
        activeSpaceID: 0,
        panels: [
            "kind": "leaf",
            "panel_id": UInt64(0),
            "tabs": [] as [[String: Any]],
            "active": 0,
            "active_tab_id": UInt64(0),
        ],
        focusedPanelID: 0,
        focusedTabID: 0,
        attachedClients: []
    )

    var payload: [String: Any] {
        [
            "workspaces": workspaces,
            "active_workspace": activeWorkspaceIndex,
            "active_workspace_id": activeWorkspaceID,
            "spaces": spaces,
            "active_space": activeSpaceIndex,
            "active_space_id": activeSpaceID,
            "panels": panels,
            "focused_panel_id": focusedPanelID,
            "focused_tab_id": focusedTabID,
            "attached_clients": attachedClients,
            "terminal_theme": NSNull(),
            "terminal_font": NSNull(),
            "terminal_cursor": NSNull(),
        ]
    }
}

private enum CmxNativeBridgeClientCommand {
    case selectWorkspace(Int)
    case selectTabInPanel(panelID: UInt64, index: Int)
    case setWorkspacePinned(workspaceID: UInt64, pinned: Bool)
    case setWorkspaceUnread(workspaceID: UInt64, unread: Bool)
    case other
}

private enum CmxNativeBridgeClientMessage {
    case hello
    case helloNative
    case nativeLayout([CmxNativeBridgeTerminalViewport])
    case requestPtyReplay(UInt64)
    case nativeInput(tabID: UInt64, data: Data)
    case command(id: UInt32, CmxNativeBridgeClientCommand)
    case ping
    case clientLatency(UInt32)
    case detach
}

private enum CmxNativeBridgeProtocol {
    static func decodeClientMessage(_ data: Data) throws -> CmxNativeBridgeClientMessage {
        var reader = CmxNativeBridgeMessagePackReader(data: data)
        let value = try reader.readValue()
        guard reader.isAtEnd else {
            throw CmxNativeBridgeSocketError.protocolError("Trailing bytes after cmx message.")
        }
        let map = try value.mapValue()
        let kind = try requiredString(map, "kind")
        switch kind {
        case "hello":
            return .hello
        case "hello_native":
            return .helloNative
        case "native_layout":
            let terminalValues: [CmxNativeBridgeMessagePackValue]
            if let value = map["terminals"] {
                terminalValues = try value.arrayValue()
            } else {
                terminalValues = []
            }
            let terminals = try terminalValues.map { value in
                let terminal = try value.mapValue()
                return CmxNativeBridgeTerminalViewport(
                    tabID: try requiredUInt(terminal, "tab_id"),
                    cols: UInt16(clamping: try requiredUInt(terminal, "cols")),
                    rows: UInt16(clamping: try requiredUInt(terminal, "rows"))
                )
            }
            return .nativeLayout(terminals)
        case "request_pty_replay":
            return .requestPtyReplay(try requiredUInt(map, "tab_id"))
        case "native_input":
            return .nativeInput(
                tabID: try requiredUInt(map, "tab_id"),
                data: try requiredData(map, "data")
            )
        case "command":
            let id = UInt32(clamping: try requiredUInt(map, "id"))
            let commandMap = try requiredMap(map, "command")
            return .command(id: id, decodeCommand(commandMap))
        case "ping":
            return .ping
        case "client_latency":
            return .clientLatency(UInt32(clamping: try requiredUInt(map, "latency_ms")))
        case "detach":
            return .detach
        default:
            throw CmxNativeBridgeSocketError.protocolError("Unsupported cmx client message \(kind).")
        }
    }

    static func encodeWelcome(sessionID: String) -> Data {
        encode([
            "kind": "welcome",
            "server_version": "cmux-macos-adapter",
            "session_id": sessionID,
        ])
    }

    static func encodeNativeSnapshot(_ snapshot: CmxNativeBridgeSnapshot) -> Data {
        encode([
            "kind": "native_snapshot",
            "snapshot": snapshot.payload,
        ])
    }

    static func encodePtyBytes(tabID: UInt64, data: Data) -> Data {
        encode([
            "kind": "pty_bytes",
            "tab_id": tabID,
            "data": data,
        ])
    }

    static func encodeCommandReply(id: UInt32) -> Data {
        encode([
            "kind": "command_reply",
            "id": UInt64(id),
        ])
    }

    static func encodePong() -> Data {
        encode(["kind": "pong"])
    }

    static func encodeBye() -> Data {
        encode(["kind": "bye"])
    }

    static func encodeError(_ message: String) -> Data {
        encode([
            "kind": "error",
            "message": message,
        ])
    }

    private static func decodeCommand(_ map: [String: CmxNativeBridgeMessagePackValue]) -> CmxNativeBridgeClientCommand {
        guard let name = try? requiredString(map, "name") else { return .other }
        switch name {
        case "select-workspace":
            let index = (try? requiredInt(map, "index")) ?? 0
            return .selectWorkspace(index)
        case "select-tab-in-panel":
            return .selectTabInPanel(
                panelID: (try? requiredUInt(map, "panel_id")) ?? 0,
                index: (try? requiredInt(map, "index")) ?? 0
            )
        case "set-workspace-pinned":
            return .setWorkspacePinned(
                workspaceID: (try? requiredUInt(map, "workspace_id")) ?? 0,
                pinned: (try? requiredBool(map, "pinned")) ?? false
            )
        case "set-workspace-unread":
            return .setWorkspaceUnread(
                workspaceID: (try? requiredUInt(map, "workspace_id")) ?? 0,
                unread: (try? requiredBool(map, "unread")) ?? false
            )
        default:
            return .other
        }
    }

    private static func encode(_ value: Any) -> Data {
        var writer = CmxNativeBridgeMessagePackWriter()
        writer.writeValue(value)
        return writer.data
    }

    private static func requiredString(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> String {
        guard let value = map[key] else {
            throw CmxNativeBridgeSocketError.protocolError("Missing \(key).")
        }
        return try value.stringValue()
    }

    private static func requiredData(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> Data {
        guard let value = map[key] else {
            throw CmxNativeBridgeSocketError.protocolError("Missing \(key).")
        }
        return try value.dataValue()
    }

    private static func requiredUInt(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> UInt64 {
        guard let value = map[key] else {
            throw CmxNativeBridgeSocketError.protocolError("Missing \(key).")
        }
        return try value.uintValue()
    }

    private static func requiredInt(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> Int {
        let value = try requiredUInt(map, key)
        guard value <= UInt64(Int.max) else {
            throw CmxNativeBridgeSocketError.protocolError("\(key) is out of range.")
        }
        return Int(value)
    }

    private static func requiredBool(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> Bool {
        guard let value = map[key] else {
            throw CmxNativeBridgeSocketError.protocolError("Missing \(key).")
        }
        return try value.boolValue()
    }

    private static func requiredMap(
        _ map: [String: CmxNativeBridgeMessagePackValue],
        _ key: String
    ) throws -> [String: CmxNativeBridgeMessagePackValue] {
        guard let value = map[key] else {
            throw CmxNativeBridgeSocketError.protocolError("Missing \(key).")
        }
        return try value.mapValue()
    }
}

private struct CmxNativeBridgeMessagePackWriter {
    private(set) var data = Data()

    mutating func writeValue(_ value: Any) {
        switch value {
        case is NSNull:
            writeNil()
        case let value as String:
            writeString(value)
        case let value as Bool:
            writeBool(value)
        case let value as Data:
            writeBinary(value)
        case let value as UInt64:
            writeUInt(value)
        case let value as UInt32:
            writeUInt(UInt64(value))
        case let value as UInt16:
            writeUInt(UInt64(value))
        case let value as UInt8:
            writeUInt(UInt64(value))
        case let value as UInt:
            writeUInt(UInt64(value))
        case let value as Int:
            if value >= 0 {
                writeUInt(UInt64(value))
            } else {
                writeInt(Int64(value))
            }
        case let value as Int64:
            if value >= 0 {
                writeUInt(UInt64(value))
            } else {
                writeInt(value)
            }
        case let value as Double:
            writeFloat64(value)
        case let array as [Any]:
            writeArrayHeader(array.count)
            for item in array {
                writeValue(item)
            }
        case let array as [[String: Any]]:
            writeArrayHeader(array.count)
            for item in array {
                writeValue(item)
            }
        case let map as [String: Any]:
            writeMapHeader(map.count)
            for key in map.keys.sorted() {
                writeString(key)
                writeValue(map[key] ?? NSNull())
            }
        default:
            writeNil()
        }
    }

    private mutating func writeNil() {
        data.append(0xC0)
    }

    private mutating func writeBool(_ value: Bool) {
        data.append(value ? 0xC3 : 0xC2)
    }

    private mutating func writeUInt(_ value: UInt64) {
        switch value {
        case 0...0x7F:
            data.append(UInt8(value))
        case 0x80...0xFF:
            data.append(0xCC)
            data.append(UInt8(value))
        case 0x100...0xFFFF:
            data.append(0xCD)
            appendBigEndian(UInt16(value))
        case 0x1_0000...0xFFFF_FFFF:
            data.append(0xCE)
            appendBigEndian(UInt32(value))
        default:
            data.append(0xCF)
            appendBigEndian(value)
        }
    }

    private mutating func writeInt(_ value: Int64) {
        if value >= 0 {
            writeUInt(UInt64(value))
        } else if value >= Int64(Int8.min) {
            data.append(0xD0)
            data.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int16.min) {
            data.append(0xD1)
            appendBigEndian(UInt16(bitPattern: Int16(value)))
        } else if value >= Int64(Int32.min) {
            data.append(0xD2)
            appendBigEndian(UInt32(bitPattern: Int32(value)))
        } else {
            data.append(0xD3)
            appendBigEndian(UInt64(bitPattern: value))
        }
    }

    private mutating func writeFloat64(_ value: Double) {
        data.append(0xCB)
        appendBigEndian(value.bitPattern)
    }

    private mutating func writeString(_ string: String) {
        let bytes = Array(string.utf8)
        let count = bytes.count
        switch count {
        case 0...31:
            data.append(0xA0 | UInt8(count))
        case 32...0xFF:
            data.append(0xD9)
            data.append(UInt8(count))
        case 0x100...0xFFFF:
            data.append(0xDA)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDB)
            appendBigEndian(UInt32(count))
        }
        data.append(contentsOf: bytes)
    }

    private mutating func writeBinary(_ binary: Data) {
        let count = binary.count
        switch count {
        case 0...0xFF:
            data.append(0xC4)
            data.append(UInt8(count))
        case 0x100...0xFFFF:
            data.append(0xC5)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xC6)
            appendBigEndian(UInt32(count))
        }
        data.append(binary)
    }

    private mutating func writeArrayHeader(_ count: Int) {
        switch count {
        case 0...15:
            data.append(0x90 | UInt8(count))
        case 16...0xFFFF:
            data.append(0xDC)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDD)
            appendBigEndian(UInt32(count))
        }
    }

    private mutating func writeMapHeader(_ count: Int) {
        switch count {
        case 0...15:
            data.append(0x80 | UInt8(count))
        case 16...0xFFFF:
            data.append(0xDE)
            appendBigEndian(UInt16(count))
        default:
            data.append(0xDF)
            appendBigEndian(UInt32(count))
        }
    }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}

private enum CmxNativeBridgeMessagePackValue {
    case nilValue
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([CmxNativeBridgeMessagePackValue])
    case map([String: CmxNativeBridgeMessagePackValue])

    func mapValue() throws -> [String: CmxNativeBridgeMessagePackValue] {
        guard case .map(let map) = self else {
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack map.")
        }
        return map
    }

    func arrayValue() throws -> [CmxNativeBridgeMessagePackValue] {
        guard case .array(let array) = self else {
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack array.")
        }
        return array
    }

    func stringValue() throws -> String {
        guard case .string(let string) = self else {
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack string.")
        }
        return string
    }

    func boolValue() throws -> Bool {
        guard case .bool(let bool) = self else {
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack bool.")
        }
        return bool
    }

    func dataValue() throws -> Data {
        guard case .binary(let data) = self else {
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack binary data.")
        }
        return data
    }

    func uintValue() throws -> UInt64 {
        switch self {
        case .uint(let value):
            return value
        case .int(let value) where value >= 0:
            return UInt64(value)
        default:
            throw CmxNativeBridgeSocketError.protocolError("Expected MessagePack integer.")
        }
    }

    var stringMapKey: String? {
        switch self {
        case .string(let value):
            return value
        case .uint(let value):
            return String(value)
        case .int(let value) where value >= 0:
            return String(value)
        default:
            return nil
        }
    }
}

private struct CmxNativeBridgeMessagePackReader {
    let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readValue() throws -> CmxNativeBridgeMessagePackValue {
        let byte = try readByte()
        switch byte {
        case 0x00...0x7F:
            return .uint(UInt64(byte))
        case 0x80...0x8F:
            return try readMap(count: Int(byte & 0x0F))
        case 0x90...0x9F:
            return try readArray(count: Int(byte & 0x0F))
        case 0xA0...0xBF:
            return try readString(count: Int(byte & 0x1F))
        case 0xC0:
            return .nilValue
        case 0xC2:
            return .bool(false)
        case 0xC3:
            return .bool(true)
        case 0xC4:
            return try readBinary(count: Int(readByte()))
        case 0xC5:
            return try readBinary(count: Int(readUInt16()))
        case 0xC6:
            return try readBinary(count: Int(readUInt32()))
        case 0xCA:
            return .float(Double(Float32(bitPattern: try readUInt32())))
        case 0xCB:
            return .float(Double(bitPattern: try readUInt64()))
        case 0xCC:
            return .uint(UInt64(try readByte()))
        case 0xCD:
            return .uint(UInt64(try readUInt16()))
        case 0xCE:
            return .uint(UInt64(try readUInt32()))
        case 0xCF:
            return .uint(try readUInt64())
        case 0xD0:
            return .int(Int64(Int8(bitPattern: try readByte())))
        case 0xD1:
            return .int(Int64(Int16(bitPattern: try readUInt16())))
        case 0xD2:
            return .int(Int64(Int32(bitPattern: try readUInt32())))
        case 0xD3:
            return .int(Int64(bitPattern: try readUInt64()))
        case 0xD9:
            return try readString(count: Int(readByte()))
        case 0xDA:
            return try readString(count: Int(readUInt16()))
        case 0xDB:
            return try readString(count: Int(readUInt32()))
        case 0xDC:
            return try readArray(count: Int(readUInt16()))
        case 0xDD:
            return try readArray(count: Int(readUInt32()))
        case 0xDE:
            return try readMap(count: Int(readUInt16()))
        case 0xDF:
            return try readMap(count: Int(readUInt32()))
        case 0xE0...0xFF:
            return .int(Int64(Int8(bitPattern: byte)))
        default:
            throw CmxNativeBridgeSocketError.protocolError(
                String(format: "Unsupported MessagePack byte 0x%02X.", byte)
            )
        }
    }

    private mutating func readMap(count: Int) throws -> CmxNativeBridgeMessagePackValue {
        guard count <= 1_000_000 else {
            throw CmxNativeBridgeSocketError.protocolError("MessagePack map is too large.")
        }
        var map: [String: CmxNativeBridgeMessagePackValue] = [:]
        map.reserveCapacity(count)
        for _ in 0..<count {
            let key = try readValue()
            let value = try readValue()
            if let stringKey = key.stringMapKey {
                map[stringKey] = value
            }
        }
        return .map(map)
    }

    private mutating func readArray(count: Int) throws -> CmxNativeBridgeMessagePackValue {
        guard count <= 1_000_000 else {
            throw CmxNativeBridgeSocketError.protocolError("MessagePack array is too large.")
        }
        var values: [CmxNativeBridgeMessagePackValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readValue())
        }
        return .array(values)
    }

    private mutating func readString(count: Int) throws -> CmxNativeBridgeMessagePackValue {
        let bytes = try readBytes(count)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw CmxNativeBridgeSocketError.protocolError("Invalid UTF-8 in MessagePack string.")
        }
        return .string(string)
    }

    private mutating func readBinary(count: Int) throws -> CmxNativeBridgeMessagePackValue {
        .binary(try readBytes(count))
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw CmxNativeBridgeSocketError.protocolError("Unexpected end of MessagePack payload.")
        }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw CmxNativeBridgeSocketError.protocolError("Unexpected end of MessagePack payload.")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readUInt16() throws -> UInt16 {
        try readFixedWidthInteger()
    }

    private mutating func readUInt32() throws -> UInt32 {
        try readFixedWidthInteger()
    }

    private mutating func readUInt64() throws -> UInt64 {
        try readFixedWidthInteger()
    }

    private mutating func readFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
        let count = MemoryLayout<T>.size
        let bytes = try readBytes(count)
        return bytes.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: T.self).bigEndian
        }
    }
}

private enum CmxNativeBridgeSocketError: LocalizedError {
    case pathTooLong(String)
    case posix(String, Int32)
    case frameTooLarge
    case protocolError(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Native bridge socket path is too long: \(path)"
        case .posix(let operation, let code):
            return "Native bridge socket \(operation) failed: \(String(cString: strerror(code)))"
        case .frameTooLarge:
            return "Native bridge cmx frame is too large."
        case .protocolError(let message):
            return message
        case .closed:
            return "Native bridge socket closed."
        }
    }
}

private struct CmxHiveNodePublishPayload: Encodable {
    let id: String
    let machineGroupID: String
    let nodeEpoch: String
    let bootID: String
    let nodeStartedAtUnix: TimeInterval
    let name: String
    let subtitle: String
    let kind: String
    let isOnline: Bool
    let leaseExpiresAtUnix: TimeInterval
    let restoreState: String
    let snapshotMode: String
    let attachTicket: String?
    let attachTicketExpiresAtUnix: UInt64?
    let workspaces: [CmxHiveWorkspacePublishPayload]

    private enum CodingKeys: String, CodingKey {
        case id
        case machineGroupID = "machine_group_id"
        case nodeEpoch = "node_epoch"
        case bootID = "boot_id"
        case nodeStartedAtUnix = "node_started_at_unix"
        case name
        case subtitle
        case kind
        case isOnline = "is_online"
        case leaseExpiresAtUnix = "lease_expires_at_unix"
        case restoreState = "restore_state"
        case snapshotMode = "snapshot_mode"
        case attachTicket = "attach_ticket"
        case attachTicketExpiresAtUnix = "attach_ticket_expires_at_unix"
        case workspaces
    }
}

private struct CmxHiveWorkspacePublishPayload: Encodable {
    let id: String
    let nodeID: String
    let workspaceKey: String
    let localWorkspaceID: String
    let title: String
    let preview: String?
    let lastActivityUnix: TimeInterval
    let unread: Bool
    let pinned: Bool
    let spaces: [CmxHiveSpacePublishPayload]

    private enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case workspaceKey = "workspace_key"
        case localWorkspaceID = "local_workspace_id"
        case title
        case preview
        case lastActivityUnix = "last_activity_unix"
        case unread
        case pinned
        case spaces
    }
}

private struct CmxHiveSpacePublishPayload: Encodable {
    let id: String
    let title: String
    let terminals: [CmxHiveTerminalPublishPayload]
}

private struct CmxHiveTerminalPublishPayload: Encodable {
    let id: String
    let title: String
    let cols: Int
    let rows: Int
    let outputRows: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case cols
        case rows
        case outputRows = "output_rows"
    }
}

private struct CmxHiveNodeIdentity: Codable {
    let nodeID: String
    let machineGroupID: String

    private enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case machineGroupID = "machine_group_id"
    }

    static func loadOrCreate() throws -> CmxHiveNodeIdentity {
        let nodeURL = nodeIdentityURL()
        let machineGroupURL = applicationSupportDirectory()
            .appendingPathComponent("machine-group.json", isDirectory: false)
        let machineGroupID = try loadOrCreateID(
            at: machineGroupURL,
            key: "machine_group_id",
            prefix: "machine"
        )
        let nodeID = try loadOrCreateID(at: nodeURL, key: "node_id", prefix: "node")
        return CmxHiveNodeIdentity(nodeID: nodeID, machineGroupID: machineGroupID)
    }

    static func ephemeral() -> CmxHiveNodeIdentity {
        CmxHiveNodeIdentity(
            nodeID: "node_\(UUID().uuidString.lowercased())",
            machineGroupID: "machine_\(UUID().uuidString.lowercased())"
        )
    }

    private static func loadOrCreateID(at url: URL, key: String, prefix: String) throws -> String {
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let value = "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let data = try JSONSerialization.data(
            withJSONObject: [key: value],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        return value
    }

    private static func nodeIdentityURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("node-identities", isDirectory: true)
            .appendingPathComponent(nodeIdentityFileName(), isDirectory: false)
    }

    private static func nodeIdentityFileName() -> String {
#if DEBUG
        if let tag = TaggedRunBadgeSettings.normalizedTag(ProcessInfo.processInfo.environment[TaggedRunBadgeSettings.environmentKey]) {
            return "dev/\(tag).json"
        }
#endif
        let bundleID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        if bundleID.contains("staging") {
            return "staging.json"
        }
        if bundleID.contains("nightly") {
            return "nightly.json"
        }
        return "stable.json"
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("cmux", isDirectory: true)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
