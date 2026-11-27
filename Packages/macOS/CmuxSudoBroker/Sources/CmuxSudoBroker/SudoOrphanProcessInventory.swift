import Foundation

struct SudoOrphanProcessInventory: Sendable {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    /// Inventories exact broker commands for every requested approved script in one scan.
    func identitiesByScriptPath(
        approvedScriptURLs: [URL]
    ) -> [String: [SudoProcessIdentity]] {
        let requestedPaths = Set(
            approvedScriptURLs.map { $0.standardizedFileURL.path }
        )
        var identitiesByPath = Dictionary(
            uniqueKeysWithValues: requestedPaths.map { ($0, [SudoProcessIdentity]()) }
        )
        guard !requestedPaths.isEmpty else { return identitiesByPath }

        for processIdentifier in inspector.allProcessIdentifiers() {
            guard let initialIdentity = inspector.identity(for: processIdentifier),
                  let arguments = inspector.arguments(for: processIdentifier),
                  let scriptPath = approvedScriptPath(arguments: arguments),
                  requestedPaths.contains(scriptPath),
                  let finalIdentity = inspector.identity(for: processIdentifier),
                  initialIdentity == finalIdentity else {
                continue
            }
            identitiesByPath[scriptPath, default: []].append(finalIdentity)
        }
        for path in identitiesByPath.keys {
            identitiesByPath[path]?.sort { $0.processIdentifier < $1.processIdentifier }
        }
        return identitiesByPath
    }

    private func approvedScriptPath(arguments: [String]) -> String? {
        let prompt = SudoAuthenticationOutputDetector.passwordPrompt
        if let path = stagedExecutorScriptPath(arguments: arguments, prompt: prompt) {
            return path
        }
        // Recover commands left by the former unstaged-helper protocol.
        if arguments.count == 14,
           arguments[0...7].elementsEqual([
               "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
               "-S", "-p", prompt,
           ]),
           arguments[9] == SudoPrivilegedExecutor.hiddenCommand {
            return arguments[12]
        }
        if arguments.count == 11,
           arguments[0...4].elementsEqual([
               "/usr/bin/sudo", "-k", "-S", "-p", prompt,
           ]),
           arguments[6] == SudoPrivilegedExecutor.hiddenCommand {
            return arguments[9]
        }
        if arguments.count == 6,
           arguments[1] == SudoPrivilegedExecutor.hiddenCommand {
            return arguments[4]
        }
        if arguments.count == 4,
           arguments[0...2].elementsEqual([
               "/bin/bash", "-c", SudoPrivilegedProcessSupervisor.sourceCommand,
           ]) {
            return arguments[3]
        }

        // Recover commands left by the former pathname-execution protocol.
        if arguments.count == 9,
           arguments[0...7].elementsEqual([
               "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
               "-p", prompt, "/bin/bash",
           ]) {
            return arguments[8]
        }
        if arguments.count == 6,
           arguments[0...4].elementsEqual([
               "/usr/bin/sudo", "-k", "-p", prompt, "/bin/bash",
           ]) {
            return arguments[5]
        }
        if arguments.count == 2, arguments[0] == "/bin/bash" {
            return arguments[1]
        }
        return nil
    }

    /// Matches the root-staged executor protocol at each layer of its process tree.
    private func stagedExecutorScriptPath(arguments: [String], prompt: String) -> String? {
        // hidden command, byte count, deadline, approved path, script digest, token
        let executorArgumentCount = 6
        let stagingCount = SudoHelperStagingCommand.prefixCount
        let scriptPrefix = [
            "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k", "-S", "-p", prompt,
        ]
        let sudoPrefix = ["/usr/bin/sudo", "-k", "-S", "-p", prompt]
        let candidates: [Int] = [
            scriptPrefix.count + stagingCount,
            sudoPrefix.count + stagingCount,
            stagingCount,
            1,
        ]
        for executorIndex in candidates {
            guard arguments.count == executorIndex + executorArgumentCount,
                  arguments[executorIndex] == SudoPrivilegedExecutor.hiddenCommand else {
                continue
            }
            let prefix = Array(arguments[..<executorIndex])
            let matchesLayer: Bool
            switch executorIndex {
            case scriptPrefix.count + stagingCount:
                matchesLayer = Array(prefix.prefix(scriptPrefix.count)) == scriptPrefix
                    && isStagingPrefix(Array(prefix.dropFirst(scriptPrefix.count)))
            case sudoPrefix.count + stagingCount:
                matchesLayer = Array(prefix.prefix(sudoPrefix.count)) == sudoPrefix
                    && isStagingPrefix(Array(prefix.dropFirst(sudoPrefix.count)))
            case stagingCount:
                matchesLayer = isStagingPrefix(prefix)
            default:
                matchesLayer = true
            }
            if matchesLayer {
                return arguments[executorIndex + 3]
            }
        }
        return nil
    }

    private func isStagingPrefix(_ prefix: [String]) -> Bool {
        prefix.count == SudoHelperStagingCommand.prefixCount
            && prefix[0] == SudoHelperStagingCommand.shell
            && prefix[1] == "-c"
            && prefix[3] == SudoHelperStagingCommand.argumentZero
    }
}
