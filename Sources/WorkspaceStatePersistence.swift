import Foundation

// MARK: - Codable Data Model

struct WorkspaceStateSnapshot: Codable {
    let version: Int
    let savedAt: Date
    let workspaces: [WorkspaceSnapshot]
    let selectedWorkspaceIndex: Int?

    init(savedAt: Date = Date(), workspaces: [WorkspaceSnapshot], selectedWorkspaceIndex: Int?) {
        self.version = 1
        self.savedAt = savedAt
        self.workspaces = workspaces
        self.selectedWorkspaceIndex = selectedWorkspaceIndex
    }
}

struct WorkspaceSnapshot: Codable {
    let stableId: String
    let title: String
    let customTitle: String?
    let customColor: String?
    let isPinned: Bool
    let currentDirectory: String
    let splitTree: SplitTreeSnapshot
    let focusedPaneIndex: Int?
}

indirect enum SplitTreeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitNodeSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            let value = try container.decode(PaneSnapshot.self, forKey: .pane)
            self = .pane(value)
        case "split":
            let value = try container.decode(SplitNodeSnapshot.self, forKey: .split)
            self = .split(value)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown SplitTreeSnapshot type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let value):
            try container.encode("pane", forKey: .type)
            try container.encode(value, forKey: .pane)
        case .split(let value):
            try container.encode("split", forKey: .type)
            try container.encode(value, forKey: .split)
        }
    }
}

struct PaneSnapshot: Codable {
    let panels: [PanelSnapshot]
    let selectedPanelIndex: Int?
}

struct SplitNodeSnapshot: Codable {
    let orientation: String
    let dividerPosition: Double
    let first: SplitTreeSnapshot
    let second: SplitTreeSnapshot
}

struct PanelSnapshot: Codable {
    let type: PanelType
    let zmxSessionName: String?
    let directory: String?
    let customTitle: String?
    let isPinned: Bool
    let browserURL: String?
}

// MARK: - Settings

enum ZmxPersistenceSettings {
    static let enabledKey = "zmxPersistenceEnabled"
    static let killOnCloseKey = "zmxKillOnWorkspaceClose"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var killOnWorkspaceClose: Bool {
        UserDefaults.standard.object(forKey: killOnCloseKey) != nil
            ? UserDefaults.standard.bool(forKey: killOnCloseKey)
            : true  // default: kill
    }
}

// MARK: - zmx Session Naming

enum ZmxSessionNaming {
    /// Generate a deterministic session name: `cmux-{8-char-hash}-{index}`
    /// Well under the 46-char zmx session name limit.
    static func sessionName(workspaceStableId: String, panelIndex: Int) -> String {
        let cleaned = workspaceStableId.replacingOccurrences(of: "-", with: "")
        return "cmux-\(String(cleaned.prefix(8)).lowercased())-\(panelIndex)"
    }

    /// Parse the panel index suffix from a zmx session name.
    /// Returns nil if the name doesn't match the expected format.
    static func parseIndex(from sessionName: String) -> Int? {
        guard sessionName.hasPrefix("cmux-") else { return nil }
        guard let lastDash = sessionName.lastIndex(of: "-") else { return nil }
        let suffix = sessionName[sessionName.index(after: lastDash)...]
        return Int(suffix)
    }
}

// MARK: - zmx Session Probe

enum ZmxSessionProbe {
    /// Resolve the zmx socket directory using the same fallback chain as zmx itself:
    /// $ZMX_DIR > $XDG_RUNTIME_DIR/zmx > $TMPDIR/zmx-{uid}
    static func socketDir() -> String {
        if let zmxDir = ProcessInfo.processInfo.environment["ZMX_DIR"], !zmxDir.isEmpty {
            return zmxDir
        }
        if let xdgRuntime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdgRuntime.isEmpty {
            return (xdgRuntime as NSString).appendingPathComponent("zmx")
        }
        let uid = getuid()
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmpDir as NSString).appendingPathComponent("zmx-\(uid)")
    }

    /// Probe session liveness via non-blocking connect() + poll() with a short timeout.
    /// File existence alone is insufficient — stale sockets can remain after daemon crash.
    static func isSessionAlive(_ name: String) -> Bool {
        let path = (socketDir() as NSString).appendingPathComponent(name)
        guard path.utf8.count < 104 else { return false }  // sun_path limit

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cStr in
                _ = memcpy(sunPath, cStr, min(path.utf8.count + 1, MemoryLayout.size(ofValue: sunPath.pointee)))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        // poll with 200ms timeout
        var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFd, 1, 200)
        guard pollResult > 0 else { return false }

        // Check SO_ERROR
        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen)
        return soError == 0
    }

    /// Check whether the zmx binary is available on PATH.
    static func isZmxAvailable() -> Bool {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let dirs = pathEnv.split(separator: ":")
        let fm = FileManager.default
        for dir in dirs {
            let candidate = "\(dir)/zmx"
            if fm.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    /// Send a zmx Kill IPC message (tag=5) to a session's socket.
    /// This terminates the zmx daemon session.
    static func killSession(_ name: String) {
        let path = (socketDir() as NSString).appendingPathComponent(name)
        guard path.utf8.count < 104 else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            path.withCString { cStr in
                _ = memcpy(sunPath, cStr, min(path.utf8.count + 1, MemoryLayout.size(ofValue: sunPath.pointee)))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return }

        // zmx IPC Kill message: 4-byte little-endian length header + 1-byte tag (5)
        var msg: [UInt8] = [1, 0, 0, 0, 5]
        _ = msg.withUnsafeBufferPointer { buf in
            send(fd, buf.baseAddress, buf.count, 0)
        }
    }
}

// MARK: - Save/Load

@MainActor
enum WorkspaceStatePersistence {
    /// Whether saves are suppressed. Recomputed before each save via refreshSaveSuppression().
    static var saveSuppressed: Bool = false

    static var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("cmux")
        return dir.appendingPathComponent("workspace-state.json")
    }

    /// Recompute saveSuppressed based on current zmx availability.
    private static func refreshSaveSuppression() {
        saveSuppressed = ZmxPersistenceSettings.isEnabled && !ZmxSessionProbe.isZmxAvailable()
    }

    static func save(tabManager: TabManager) {
        refreshSaveSuppression()
        guard ZmxPersistenceSettings.isEnabled, !saveSuppressed else { return }
        guard let url = fileURL else { return }

        let selectedIndex: Int? = {
            guard let selectedId = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.firstIndex(where: { $0.id == selectedId })
        }()

        let workspaceSnapshots = tabManager.tabs.map { workspace in
            workspace.generateSnapshot()
        }

        let snapshot = WorkspaceStateSnapshot(
            workspaces: workspaceSnapshots,
            selectedWorkspaceIndex: selectedIndex
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            // Ensure directory exists
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Atomic write
            try data.write(to: url, options: .atomic)
        } catch {
            #if DEBUG
            NSLog("[WorkspaceStatePersistence] save failed: \(error)")
            #endif
        }
    }

    static func load() -> WorkspaceStateSnapshot? {
        guard let url = fileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(WorkspaceStateSnapshot.self, from: data)
            guard snapshot.version == 1 else {
                #if DEBUG
                NSLog("[WorkspaceStatePersistence] unknown version: \(snapshot.version)")
                #endif
                return nil
            }
            return snapshot
        } catch {
            #if DEBUG
            NSLog("[WorkspaceStatePersistence] load failed: \(error)")
            #endif
            return nil
        }
    }
}
