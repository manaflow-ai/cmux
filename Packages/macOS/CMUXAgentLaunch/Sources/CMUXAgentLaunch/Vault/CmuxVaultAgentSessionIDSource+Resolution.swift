public import Foundation

/// Where a Vault agent's resumable session identifier was obtained from when a
/// running process is detected.
///
/// `explicit` means the identifier came straight from the process (an argv
/// option value, a `pi`-compatible session id on the command line, or a grok
/// resume id); `inferredLatestSessionFile` means no identifier was present on
/// the process and the newest on-disk session file was chosen as a best guess.
/// A pure value enum with no associated state, so it crosses isolation freely.
public enum ProcessDetectedSessionIDSource: Sendable {
    /// The identifier was read directly from the detected process.
    case explicit
    /// No identifier was present; the newest session file on disk was inferred.
    case inferredLatestSessionFile
}

/// A resolved session identifier paired with how it was obtained, the result of
/// resolving a detected process against its registration.
public struct VaultAgentSessionIDResolution: Sendable {
    /// The resolved resumable session identifier.
    public let sessionId: String
    /// How `sessionId` was obtained from the detected process.
    public let source: ProcessDetectedSessionIDSource

    /// Creates a resolution.
    ///
    /// - Parameters:
    ///   - sessionId: The resolved resumable session identifier.
    ///   - source: How the identifier was obtained.
    public init(sessionId: String, source: ProcessDetectedSessionIDSource) {
        self.sessionId = sessionId
        self.source = source
    }
}

extension CmuxVaultAgentSessionIDSource {
    /// Resolves the resumable session identifier for a detected `process` from
    /// this source, using `registration` to locate on-disk session layouts.
    ///
    /// Returns `nil` when this source yields no identifier for the process
    /// (e.g. an `argvOption` source whose option is absent, or a session-file
    /// source with neither an explicit id nor any session file on disk).
    public func sessionIDResolution(
        from process: VaultObservedAgentProcess,
        registration: CmuxVaultAgentRegistration,
        fileManager: FileManager
    ) -> VaultAgentSessionIDResolution? {
        switch self {
        case .argvOption(let option):
            guard let sessionId = process.arguments.nonOptionValue(afterOption: option) else { return nil }
            return VaultAgentSessionIDResolution(sessionId: sessionId, source: .explicit)
        case .piSessionFile:
            let locator = PiSessionLocator(fileManager: fileManager)
            let piRegistration = registration.piSessionRegistration
            if let session = process.piCompatibleSessionID {
                let sessionId = locator.resolvedSessionPath(
                    session,
                    for: process,
                    registration: piRegistration
                ) ?? session
                return VaultAgentSessionIDResolution(sessionId: sessionId, source: .explicit)
            }
            guard let sessionId = locator.latestSessionPath(
                for: process,
                registration: piRegistration
            ) else {
                return nil
            }
            return VaultAgentSessionIDResolution(sessionId: sessionId, source: .inferredLatestSessionFile)
        case .grokSessionDirectory:
            if let session = process.arguments.grokResumeSessionID {
                return VaultAgentSessionIDResolution(sessionId: session, source: .explicit)
            }
            return nil
        }
    }
}

extension CmuxVaultAgentRegistration {
    /// The package-side ``PiSessionRegistration`` value carrying the three fields
    /// `PiSessionLocator` reads, decoupling the locator from any app registry type.
    var piSessionRegistration: PiSessionRegistration {
        PiSessionRegistration(
            id: id,
            sessionDirectory: sessionDirectory,
            builtInOmpSessionDirectory: CmuxVaultAgentRegistration.builtInOmp.sessionDirectory
        )
    }
}
