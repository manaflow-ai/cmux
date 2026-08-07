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
        let bootstrap = SudoReviewedScriptTransport.bootstrap
        if arguments.count == 13,
           arguments[0...9].elementsEqual([
               "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
               "-p", prompt, "/bin/bash", "-c", bootstrap,
           ]) {
            return arguments[10]
        }
        if arguments.count == 10,
           arguments[0...6].elementsEqual([
               "/usr/bin/sudo", "-k", "-p", prompt, "/bin/bash", "-c", bootstrap,
           ]) {
            return arguments[7]
        }
        if arguments.count == 6,
           arguments[0...2].elementsEqual([
               "/bin/bash", "-c", bootstrap,
           ]) {
            return arguments[3]
        }
        if arguments.count == 4,
           arguments[0...2].elementsEqual([
               "/bin/bash", "-c", SudoReviewedScriptTransport.sourcedScriptCommand,
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
}
