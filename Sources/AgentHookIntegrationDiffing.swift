import AppKit
import Darwin
import Foundation

extension AgentHookIntegrationSettings {
    static func buildHookDiff(for agent: AgentHookIntegration) -> AgentHookDiffResult {
        let fm = FileManager.default
        let tempHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-agent-hook-diff-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempHome) }

            guard let configDir = agent.configDir else {
                return AgentHookDiffResult(
                    succeeded: false,
                    message: String(localized: "agentHooks.diff.failed", defaultValue: "Could not prepare hook diff."),
                    diff: ""
                )
            }

            let originalConfigDir = URL(
                fileURLWithPath: configDirectoryPath(for: agent) ?? expandedHomePath(configDir).path,
                isDirectory: true
            )
            let tempConfigDir = tempHome.appendingPathComponent(configDir, isDirectory: true)
            try fm.createDirectory(at: tempConfigDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: originalConfigDir.path) {
                try fm.copyItem(at: originalConfigDir, to: tempConfigDir)
            } else {
                try fm.createDirectory(at: tempConfigDir, withIntermediateDirectories: true)
            }

            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = tempHome.path
            if let envKey = agent.configDirEnvOverride {
                environment[envKey] = tempConfigDir.path
            }

            let launch = hookInstallLaunch(for: agent)
            let installResult = runInstallCommand(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: environment,
                fallbackCommand: agent.installCommand
            )
            guard installResult.succeeded else {
                return AgentHookDiffResult(succeeded: false, message: installResult.message, diff: "")
            }

            let relativePaths = diffRelativePaths(for: agent)
            let configPrefix = "\(configDir)/"
            let diffs = relativePaths.compactMap { relativePath in
                let configRelativePath = relativePath.hasPrefix(configPrefix)
                    ? String(relativePath.dropFirst(configPrefix.count))
                    : relativePath
                let oldURL = originalConfigDir.appendingPathComponent(configRelativePath)
                let newURL = tempHome.appendingPathComponent(relativePath)
                return unifiedDiff(relativePath: relativePath, oldURL: oldURL, newURL: newURL)
            }
            let diff = diffs.joined(separator: "\n")
            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentHookDiffResult(
                    succeeded: true,
                    message: String(localized: "agentHooks.diff.noChanges", defaultValue: "No file changes needed."),
                    diff: String(localized: "agentHooks.diff.noChanges", defaultValue: "No file changes needed.")
                )
            }
            return AgentHookDiffResult(succeeded: true, message: "", diff: diff)
        } catch {
            return AgentHookDiffResult(
                succeeded: false,
                message: String(localized: "agentHooks.diff.failed", defaultValue: "Could not prepare hook diff."),
                diff: ""
            )
        }
    }

    private static func expandedHomePath(_ relativePath: String) -> URL {
        URL(fileURLWithPath: NSString(string: "~/\(relativePath)").expandingTildeInPath)
    }

    private static func diffRelativePaths(for agent: AgentHookIntegration) -> [String] {
        guard let configDir = agent.configDir,
              let configFile = agent.configFile else {
            return []
        }
        var paths = ["\(configDir)/\(configFile)"]
        if agent.name == "codex" {
            paths.append("\(configDir)/config.toml")
        }
        return paths
    }

    private static func unifiedDiff(relativePath: String, oldURL: URL, newURL: URL) -> String? {
        let oldText = (try? String(contentsOf: oldURL, encoding: .utf8)) ?? ""
        let newText = (try? String(contentsOf: newURL, encoding: .utf8)) ?? ""
        guard oldText != newText else { return nil }

        let oldLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines = [
            "--- ~/\(relativePath)",
            "+++ ~/\(relativePath)",
            "@@",
        ]
        lines.append(contentsOf: oldLines.map { "-\($0)" })
        lines.append(contentsOf: newLines.map { "+\($0)" })
        return lines.joined(separator: "\n")
    }

    private static func watchedConfigFilePaths() -> Set<String> {
        var paths: Set<String> = []
        for agent in allAgents where !agent.isClaudeWrapper {
            if let configFilePath = configFilePath(for: agent) {
                paths.insert(configFilePath)
            }
            if agent.name == "codex",
               let configDirectoryPath = configDirectoryPath(for: agent) {
                paths.insert((configDirectoryPath as NSString).appendingPathComponent("config.toml"))
            }
        }
        return paths
    }

    private static func watchedConfigPaths() -> Set<String> {
        let fm = FileManager.default
        var paths: Set<String> = []
        for filePath in watchedConfigFilePaths() {
            let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
            if fm.fileExists(atPath: fileURL.path) {
                paths.insert(fileURL.path)
            }
            if let parentURL = nearestExistingAncestor(for: fileURL.deletingLastPathComponent()) {
                paths.insert(parentURL.path)
            }
        }
        return paths
    }

    private static func nearestExistingAncestor(for url: URL) -> URL? {
        let fm = FileManager.default
        var current = url.standardizedFileURL
        while true {
            if fm.fileExists(atPath: current.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    final class ConfigFileWatcher {
        private let queue = DispatchQueue(label: "com.cmuxterm.agent-hook-config-watcher", qos: .utility)
        private var isStarted = false
        private var watchedPaths: Set<String> = []
        private var sources: [String: DispatchSourceFileSystemObject] = [:]

        func startIfNeeded() {
            queue.async { [weak self] in
                guard let self, !isStarted else { return }
                isStarted = true
                rebuildWatchedPaths()
            }
        }

        func refreshWatchedPaths() {
            queue.async { [weak self] in
                guard let self, isStarted else { return }
                rebuildWatchedPaths()
            }
        }

        private func rebuildWatchedPaths() {
            let nextPaths = AgentHookIntegrationSettings.watchedConfigPaths()
            for path in watchedPaths.subtracting(nextPaths) {
                sources.removeValue(forKey: path)?.cancel()
            }
            for path in nextPaths.subtracting(watchedPaths) {
                startWatching(path: path)
            }
            watchedPaths = Set(sources.keys)
        }

        private func startWatching(path: String) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.handleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources[path] = source
            source.resume()
        }

        private func handleChange() {
            rebuildWatchedPaths()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AgentHookIntegrationSettings.statusDidChangeNotification, object: nil)
            }
        }
    }

    static func runInstallCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        fallbackCommand: String
    ) -> AgentHookInstallResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return AgentHookInstallResult(
                succeeded: false,
                message: String(localized: "agentHooks.prompt.installFailed", defaultValue: "Could not install hooks. Run \(fallbackCommand) in a terminal.")
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = output
            if detail.isEmpty {
                return AgentHookInstallResult(
                    succeeded: false,
                    message: String(localized: "agentHooks.prompt.installFailed", defaultValue: "Could not install hooks. Run \(fallbackCommand) in a terminal.")
                )
            }
            return AgentHookInstallResult(succeeded: false, message: detail)
        }

        return AgentHookInstallResult(
            succeeded: true,
            message: String(localized: "agentHooks.prompt.installSucceeded", defaultValue: "Hooks installed.")
        )
    }
}
