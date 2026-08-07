import Foundation

struct SudoOrphanProcessInventory: Sendable {
    private let inspector: any SudoProcessInspecting

    init(inspector: any SudoProcessInspecting) {
        self.inspector = inspector
    }

    /// Finds only exact broker commands that reference one approved script.
    func identities(approvedScriptURL: URL) -> [SudoProcessIdentity] {
        let path = approvedScriptURL.standardizedFileURL.path
        let expectedArguments: Set<[String]> = [
            [
                "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
                "-p", SudoAuthenticationOutputDetector.passwordPrompt,
                "/bin/bash", path,
            ],
            [
                "/usr/bin/sudo", "-k", "-p",
                SudoAuthenticationOutputDetector.passwordPrompt, "/bin/bash", path,
            ],
            ["/bin/bash", path],
        ]
        return inspector.allProcessIdentifiers().compactMap { processIdentifier in
            guard let arguments = inspector.arguments(for: processIdentifier),
                  expectedArguments.contains(arguments),
                  let identity = inspector.identity(for: processIdentifier) else {
                return nil
            }
            return identity
        }.sorted { $0.processIdentifier < $1.processIdentifier }
    }
}
