import Bonsplit
import Combine
import Foundation

struct CmuxConfigFile: Codable, Sendable {
    var commands: [CmuxCommandDefinition]
}

struct CmuxCommandDefinition: Codable, Sendable, Identifiable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: CmuxRestartBehavior?
    var workspace: CmuxWorkspaceDefinition?
    var command: String?
    var confirm: Bool?

    var id: String {
        "cmuxConfig." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }
}

enum CmuxRestartBehavior: String, Codable, Sendable {
    case recreate
    case ignore
    case confirm
}

struct CmuxWorkspaceDefinition: Codable, Sendable {
    var name: String?
    var cwd: String?
    var color: String?
    var layout: CmuxLayoutNode?
}

indirect enum CmuxLayoutNode: Codable, Sendable {
    case pane(CmuxPaneDefinition)
    case split(CmuxSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.pane) {
            let pane = try container.decode(CmuxPaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if container.contains(.direction) {
            let splitDef = try CmuxSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "CmuxLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

struct CmuxSplitDefinition: Codable, Sendable {
    var direction: CmuxSplitDirection
    var split: Double?
    var children: [CmuxLayoutNode]

    var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum CmuxSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct CmuxPaneDefinition: Codable, Sendable {
    var surfaces: [CmuxSurfaceDefinition]
}

struct CmuxSurfaceDefinition: Codable, Sendable {
    var type: CmuxSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum CmuxSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
}

@MainActor
final class CmuxConfigStore: ObservableObject {
    static let shared = CmuxConfigStore()

    @Published private(set) var loadedCommands: [CmuxCommandDefinition] = []
    @Published private(set) var configRevision: UInt64 = 0

    private var localConfigPath: String?
    private let globalConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }()

    private var cancellables = Set<AnyCancellable>()
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    private var localFileDescriptor: Int32 = -1
    private var globalFileWatchSource: DispatchSourceFileSystemObject?
    private var globalFileDescriptor: Int32 = -1
    private let watchQueue = DispatchQueue(label: "com.cmux.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    init() {
        startGlobalFileWatcher()
    }

    deinit {
        localFileWatchSource?.cancel()
        globalFileWatchSource?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        cancellables.removeAll()

        tabManager.$selectedTabId
            .compactMap { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map { workspace -> AnyPublisher<String, Never> in
                workspace.$currentDirectory.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &cancellables)

        if let directory = tabManager.selectedWorkspace?.currentDirectory {
            updateLocalConfigPath(directory)
        }
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            newPath = (directory as NSString).appendingPathComponent("cmux.json")
        } else {
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    func loadAll() {
        var commands: [CmuxCommandDefinition] = []
        var seenNames = Set<String>()

        // Local config takes precedence
        if let localPath = localConfigPath {
            if let localConfig = parseConfig(at: localPath) {
                for command in localConfig.commands {
                    if !seenNames.contains(command.name) {
                        commands.append(command)
                        seenNames.insert(command.name)
                    }
                }
            }
        }

        // Global config fills in the rest
        if let globalConfig = parseConfig(at: globalConfigPath) {
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                }
            }
        }

        loadedCommands = commands
        configRevision &+= 1
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> CmuxConfigFile? {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
        } catch {
            NSLog("[CmuxConfig] parse error at %@: %@", path, String(describing: error))
            return nil
        }
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let dirPath = (path as NSString).deletingLastPathComponent
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let configPath = self.localConfigPath,
                      FileManager.default.fileExists(atPath: configPath) else { return }
                // File appeared — switch to file-level watching
                self.stopLocalFileWatcher()
                self.loadAll()
                self.startLocalFileWatcher()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        localFileDescriptor = -1
    }

    // MARK: - File watching (global)

    private func startGlobalFileWatcher() {
        let fd = open(globalConfigPath, O_EVTONLY)
        guard fd >= 0 else {
            startGlobalDirectoryWatcher()
            return
        }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopGlobalFileWatcher()
                    self.loadAll()
                    self.scheduleGlobalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
    }

    private func scheduleGlobalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else {
            startGlobalDirectoryWatcher()
            return
        }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: self.globalConfigPath) {
                    self.loadAll()
                    self.startGlobalFileWatcher()
                } else {
                    self.scheduleGlobalReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func startGlobalDirectoryWatcher() {
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        globalFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.globalConfigPath) else { return }
                self.stopGlobalFileWatcher()
                self.loadAll()
                self.startGlobalFileWatcher()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        globalFileWatchSource = source
    }

    private func stopGlobalFileWatcher() {
        if let source = globalFileWatchSource {
            source.cancel()
            globalFileWatchSource = nil
        }
        globalFileDescriptor = -1
    }
}

extension CmuxConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
