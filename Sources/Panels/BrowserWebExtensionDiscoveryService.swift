import Foundation

/// Discovers Safari web extensions registered with the system.
///
/// Uses `pluginkit -m -p com.apple.Safari.web-extension` — the same registry
/// Safari itself consults — so anything the user installed via an app bundle
/// (Bitwarden, 1Password, AdGuard, …) is found without configuration.
actor BrowserWebExtensionDiscoveryService {
    private static let pluginkitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    private static let pluginkitTimeout: Duration = .seconds(10)
    private var activePluginkitProcess: Process?
    private var activePluginkitStdout: Pipe?

    func discoverInstalledSafariExtensions() async -> [BrowserWebExtensionCandidate] {
        let output: String
        do {
            output = try await runPluginkit()
        } catch {
            return []
        }
        return Self.parse(pluginkitOutput: output)
    }

    /// Parses `pluginkit -m -A -v` output. The tool is human-readable rather
    /// than a documented TSV format, so each line is parsed by extracting the
    /// `.appex` path first, then reading the leading identifier/version field.
    static func parse(pluginkitOutput: String) -> [BrowserWebExtensionCandidate] {
        var seen = Set<String>()
        var candidates: [BrowserWebExtensionCandidate] = []
        for line in pluginkitOutput.split(separator: "\n") {
            let rawLine = String(line).trimmingCharacters(in: .whitespaces)
            guard let pathRange = Self.appexPathRange(in: rawLine) else { continue }
            let path = String(rawLine[pathRange])
            let prefix = String(rawLine[..<pathRange.lowerBound])
            guard let parsed = Self.identifierAndVersion(from: prefix) else { continue }
            let identifier = parsed.identifier
            let version = parsed.version
            guard !identifier.isEmpty, seen.insert(identifier).inserted else { continue }
            candidates.append(BrowserWebExtensionCandidate(
                id: identifier,
                kind: .safariAppExtension,
                path: path,
                version: version,
                displayName: Self.displayName(forAppexAt: path)
            ))
        }
        return candidates.sorted { $0.id < $1.id }
    }

    private static func appexPathRange(in line: String) -> Range<String.Index>? {
        guard let start = line.firstIndex(of: "/") else { return nil }
        guard let end = line.range(of: ".appex", range: start..<line.endIndex)?.upperBound else { return nil }
        return start..<end
    }

    private static func identifierAndVersion(from prefix: String) -> (identifier: String, version: String?)? {
        let normalizedPrefix = prefix
            .split(separator: "\t")
            .first
            .map(String.init) ?? prefix
        let trimmedPrefix = normalizedPrefix.trimmingCharacters(in: .whitespaces)
        let pattern = #"^[+\-!?=\s]*([A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+)(?:\(([^)]*)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmedPrefix.startIndex..<trimmedPrefix.endIndex, in: trimmedPrefix)
        guard let match = regex.firstMatch(in: trimmedPrefix, range: range) else { return nil }
        guard let identifierRange = Range(match.range(at: 1), in: trimmedPrefix) else { return nil }
        let identifier = String(trimmedPrefix[identifierRange]).trimmingCharacters(in: .whitespaces)
        let version: String?
        if match.range(at: 2).location != NSNotFound,
           let versionRange = Range(match.range(at: 2), in: trimmedPrefix) {
            version = String(trimmedPrefix[versionRange]).trimmingCharacters(in: .whitespaces)
        } else {
            version = nil
        }
        return (identifier, version?.isEmpty == true ? nil : version)
    }

    /// Prefers the containing app's name ("Bitwarden") over the appex's own
    /// bundle name, which is often a generic "safari".
    private static func displayName(forAppexAt path: String) -> String? {
        let appexURL = URL(fileURLWithPath: path)
        // …/SomeApp.app/Contents/PlugIns/foo.appex → SomeApp.app
        let containingApp = appexURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if containingApp.pathExtension == "app" {
            return containingApp.deletingPathExtension().lastPathComponent
        }
        guard let bundle = Bundle(url: appexURL) else { return nil }
        return (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
    }

    private func runPluginkit() async throws -> String {
        try await withTaskCancellationHandler {
            try startPluginkitProcess()
            return try await readActivePluginkitOutputWithTimeout()
        } onCancel: {
            Task { await self.terminateActivePluginkitProcess() }
        }
    }

    private func startPluginkitProcess() throws {
        let process = Process()
        process.executableURL = Self.pluginkitURL
        process.arguments = ["-m", "-p", "com.apple.Safari.web-extension", "-A", "-v"]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard rather than pipe stderr: an undrained pipe could block the
        // child if it wrote enough diagnostics, hanging discovery.
        process.standardError = FileHandle.nullDevice
        activePluginkitProcess = process
        activePluginkitStdout = stdout
        try process.run()
    }

    private func readActivePluginkitOutputWithTimeout() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readActivePluginkitOutput() }
            group.addTask {
                // This bounded sleep is the intended subprocess deadline; the
                // task group cancels it as soon as pluginkit reaches EOF.
                try await Task.sleep(for: Self.pluginkitTimeout)
                await self.terminateActivePluginkitProcess()
                throw CancellationError()
            }
            do {
                let output = try await group.next() ?? ""
                group.cancelAll()
                clearActivePluginkitProcess()
                return output
            } catch {
                group.cancelAll()
                terminateActivePluginkitProcess()
                throw error
            }
        }
    }

    private func readActivePluginkitOutput() async throws -> String {
        guard let stdout = activePluginkitStdout else { return "" }
        var data = Data()
        // EOF on stdout is the completion signal; pluginkit's exit status is
        // uninteresting (an empty listing and a failure both mean "none found").
        for try await byte in stdout.fileHandleForReading.bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func terminateActivePluginkitProcess() {
        if let process = activePluginkitProcess, process.isRunning {
            process.terminate()
        }
        try? activePluginkitStdout?.fileHandleForReading.close()
        clearActivePluginkitProcess()
    }

    private func clearActivePluginkitProcess() {
        activePluginkitProcess = nil
        activePluginkitStdout = nil
    }
}
