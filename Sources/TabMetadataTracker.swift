import Foundation

final class TabMetadataTracker {
    static let shared = TabMetadataTracker()

    private weak var tabManager: TabManager?
    private var portScanTimer: Timer?
    private let backgroundQueue = DispatchQueue(label: "dev.cmux.metadata", qos: .utility)

    // Cache: directory -> (branch, timestamp)
    private var branchCache: [String: (branch: String?, timestamp: Date)] = [:]
    private let branchCacheTTL: TimeInterval = 5.0

    private init() {}

    func start(tabManager: TabManager) {
        self.tabManager = tabManager
        portScanTimer?.invalidate()
        portScanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.scanPorts()
        }
        // Run an initial port scan shortly after start
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.scanPorts()
        }
    }

    func stop() {
        portScanTimer?.invalidate()
        portScanTimer = nil
        tabManager = nil
    }

    // MARK: - Git Branch Detection

    func detectBranch(tabId: UUID, surfaceId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check cache
        if let cached = branchCache[trimmed],
           Date().timeIntervalSince(cached.timestamp) < branchCacheTTL {
            DispatchQueue.main.async { [weak self] in
                self?.applyBranch(cached.branch, tabId: tabId, surfaceId: surfaceId)
            }
            return
        }

        backgroundQueue.async { [weak self] in
            guard let self else { return }
            let branch = self.gitBranch(for: trimmed)
            self.branchCache[trimmed] = (branch, Date())
            DispatchQueue.main.async { [weak self] in
                self?.applyBranch(branch, tabId: tabId, surfaceId: surfaceId)
            }
        }
    }

    private func applyBranch(_ branch: String?, tabId: UUID, surfaceId: UUID) {
        guard let tabManager else { return }
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return }
        tab.updateSurfaceBranch(surfaceId: surfaceId, branch: branch)
    }

    private func gitBranch(for directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"]
        process.environment = [
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/usr/local/bin"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // 2-second timeout
        let deadline = DispatchTime.now() + 2.0
        let done = DispatchSemaphore(value: 0)
        backgroundQueue.async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty { return nil }

        // Detached HEAD: rev-parse returns "HEAD"
        if output == "HEAD" {
            return gitShortHash(for: directory)
        }

        return output
    }

    private func gitShortHash(for directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "rev-parse", "--short", "HEAD"]
        process.environment = [
            "GIT_TERMINAL_PROMPT": "0",
            "PATH": "/usr/bin:/usr/local/bin"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? nil : output
    }

    // MARK: - Port Scanning

    private func scanPorts() {
        guard let tabManager else { return }

        // Snapshot tab directories on main thread
        var tabDirectories: [(tabId: UUID, directories: Set<String>)] = []
        for tab in tabManager.tabs {
            var dirs = Set(tab.surfaceDirectories.values)
            let current = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty {
                dirs.insert(current)
            }
            tabDirectories.append((tabId: tab.id, directories: dirs))
        }

        backgroundQueue.async { [weak self] in
            guard let self else { return }
            let pidPorts = self.getListeningPorts()
            guard !pidPorts.isEmpty else {
                // Clear all tabs' ports
                DispatchQueue.main.async { [weak self] in
                    guard let tabManager = self?.tabManager else { return }
                    for tab in tabManager.tabs {
                        tab.updateListeningPorts([])
                    }
                }
                return
            }

            // Get CWD for each PID and match to tabs
            var tabPorts: [UUID: Set<UInt16>] = [:]
            for (pid, ports) in pidPorts {
                guard let pidCwd = self.processCwd(pid: pid) else { continue }
                for (tabId, directories) in tabDirectories {
                    for dir in directories {
                        if pidCwd == dir || pidCwd.hasPrefix(dir + "/") {
                            tabPorts[tabId, default: []].formUnion(ports)
                            break
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let tabManager = self?.tabManager else { return }
                for tab in tabManager.tabs {
                    let ports = tabPorts[tab.id].map { Array($0).sorted() } ?? []
                    tab.updateListeningPorts(ports)
                }
            }
        }
    }

    /// Parse `lsof` output to get PID -> listening ports mapping
    private func getListeningPorts() -> [pid_t: Set<UInt16>] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "TCP", "-sTCP:LISTEN", "-n", "-P", "-F", "pcn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [pid_t: Set<UInt16>] = [:]
        var currentPid: pid_t?

        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                if let pid = pid_t(line.dropFirst()) {
                    currentPid = pid
                }
            } else if line.hasPrefix("n"), let pid = currentPid {
                // Format: n*:PORT or n[addr]:PORT
                let name = String(line.dropFirst())
                if let port = parsePort(from: name) {
                    result[pid, default: []].insert(port)
                }
            }
        }

        return result
    }

    private func parsePort(from name: String) -> UInt16? {
        // lsof -F n format: "*:PORT" or "127.0.0.1:PORT" or "[::1]:PORT"
        guard let lastColon = name.lastIndex(of: ":") else { return nil }
        let portStr = name[name.index(after: lastColon)...]
        return UInt16(portStr)
    }

    /// Get the CWD of a process using proc_pidinfo (kernel API, very fast)
    private func processCwd(pid: pid_t) -> String? {
        let pathInfoSize = MemoryLayout<proc_vnodepathinfo>.size
        let buffer = UnsafeMutablePointer<proc_vnodepathinfo>.allocate(capacity: 1)
        defer { buffer.deallocate() }

        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, buffer, Int32(pathInfoSize))
        guard ret == Int32(pathInfoSize) else { return nil }

        let vip = buffer.pointee.pvi_cdir.vip_path
        return withUnsafePointer(to: vip) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { charPtr in
                String(cString: charPtr)
            }
        }
    }
}
