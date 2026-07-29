import CMUXAgentLaunch
import Foundation

extension PiSessionLocator {
    static func candidateSessionDirectories(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> [String] {
        if registration.id == CmuxVaultAgentRegistration.builtInOmp.id {
            return ompCandidateSessionDirectories(
                for: process,
                registration: registration,
                fileManager: fileManager
            )
        }

        let sessionRoot = process.arguments.sessionDirectoryValue(afterOption: "--session-dir")
            ?? piConfiguredSessionDirectory(for: process, registration: registration)
            ?? configuredSessionDirectory(for: registration)
            ?? campfireAgentSessionsRoot(for: process, registration: registration)
            ?? registration.sessionDirectory
            ?? defaultSessionsRoot()
        return candidateSessionDirectories(
            root: sessionRoot,
            workingDirectory: process.environment["CMUX_AGENT_LAUNCH_CWD"] ?? process.environment["PWD"]
        )
    }

    private static func ompCandidateSessionDirectories(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> [String] {
        let environmentPath = { (name: String) -> String? in
            guard let value = process.environment[name], !value.isEmpty else { return nil }
            return value
        }
        let homeDirectory = environmentPath("HOME") ?? NSHomeDirectory()
        let fallbackCurrentDirectory = environmentPath("CMUX_AGENT_LAUNCH_CWD")
            ?? environmentPath("PWD")
            ?? homeDirectory
        let resolver = OmpDirectoryResolver()
        let resolution = try? resolver.resolve(
            arguments: process.arguments,
            environment: process.environment,
            homeDirectory: homeDirectory,
            currentDirectory: fallbackCurrentDirectory,
            fileManager: fileManager
        )

        let builtInSessionDirectory = CmuxVaultAgentRegistration.builtInOmp.sessionDirectory
        let configuredSessionRoot = registration.sessionDirectory.flatMap { directory -> String? in
            guard directory != builtInSessionDirectory else { return nil }
            return expandedOmpRegistrationSessionRoot(directory, homeDirectory: homeDirectory)
        }
        guard let sessionRoot = configuredSessionRoot ?? resolution?.sessionRoot.path else {
            return []
        }
        let usesCwdBuckets = configuredSessionRoot != nil
            || resolution?.sessionRoot.usesCwdBuckets == true
        guard usesCwdBuckets else {
            return [sessionRoot]
        }

        let currentDirectory = resolution?.currentDirectory ?? fallbackCurrentDirectory
        let buckets = resolver.cwdBucketNames(
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        return buckets.searchOrder.map {
            (sessionRoot as NSString).appendingPathComponent($0)
        }
    }

    private static func expandedOmpRegistrationSessionRoot(
        _ rawPath: String,
        homeDirectory: String
    ) -> String? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            return (homeDirectory as NSString).standardizingPath
        }
        if path.hasPrefix("~/") {
            return ((homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2))) as NSString)
                .standardizingPath
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func candidateSessionDirectories(
        root: String,
        workingDirectory: String?
    ) -> [String] {
        let expandedRoot = (root as NSString).expandingTildeInPath
        guard let workingDirectory,
              let projectDirectory = projectDirectoryName(for: workingDirectory) else {
            return [expandedRoot]
        }
        return [(expandedRoot as NSString).appendingPathComponent(projectDirectory)]
    }

    /// Reads `PI_CODING_AGENT_SESSION_DIR` for Pi-based agents other than OMP and Campfire.
    ///
    /// Campfire embeds Pi, so a Campfire process can inherit
    /// `PI_CODING_AGENT_SESSION_DIR` from a user's Pi configuration. OMP has its
    /// own directory resolution contract and deliberately ignores the legacy
    /// variable.
    static func piConfiguredSessionDirectory(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard registration.id != "campfire", registration.id != "omp" else { return nil }
        return process.environment["PI_CODING_AGENT_SESSION_DIR"]
    }

    static func campfireAgentSessionsRoot(
        for process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        guard registration.id == "campfire" else { return nil }
        if let sessionRoot = nonEmptyEnvironmentValue("CAMPFIRE_CODING_AGENT_SESSION_DIR", in: process.environment) {
            return NSString(string: sessionRoot).expandingTildeInPath
        }
        guard let agentRoot = nonEmptyEnvironmentValue("CAMPFIRE_CODING_AGENT_DIR", in: process.environment) else {
            return nil
        }
        let expandedAgentRoot = NSString(string: agentRoot).expandingTildeInPath
        return (expandedAgentRoot as NSString).appendingPathComponent("sessions")
    }

    static func configuredSessionDirectory(for registration: CmuxVaultAgentRegistration) -> String? {
        guard let sessionDirectory = registration.sessionDirectory else { return nil }
        if registration.id == "campfire",
           sessionDirectory == CmuxVaultAgentRegistration.builtInCampfire.sessionDirectory {
            return nil
        }
        return sessionDirectory
    }

    static func nonEmptyEnvironmentValue(_ name: String, in environment: [String: String]) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func newestJSONLFile(
        in directories: [String],
        fileManager: FileManager = .default
    ) -> URL? {
        var newest: (url: URL, modified: Date, directoryIndex: Int)?
        for (directoryIndex, directory) in directories.enumerated() {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                      at: URL(fileURLWithPath: directory, isDirectory: true),
                      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
                if newest == nil
                    || modified > newest!.modified
                    || (modified == newest!.modified && directoryIndex < newest!.directoryIndex)
                    || (modified == newest!.modified
                        && directoryIndex == newest!.directoryIndex
                        && url.path < newest!.url.path) {
                    newest = (url, modified, directoryIndex)
                }
            }
        }
        return newest?.url
    }
}

private extension Array where Element == String {
    func sessionDirectoryValue(afterOption option: String) -> String? {
        for index in indices {
            let argument = self[index]
            if argument == option {
                let nextIndex = self.index(after: index)
                guard nextIndex < endIndex else { return nil }
                let value = self[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let prefix = option + "="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
