import Foundation

/// What to move and where.
public struct AgentMoveRequest: Sendable, Equatable {
    /// The Claude session id (a UUID).
    public var sessionID: String
    /// Where the session is now.
    public var source: AgentMoveEndpoint
    /// Where it should resume.
    public var destination: AgentMoveEndpoint
    /// The home directory of the local machine.
    public var localHome: String
    /// Whether to carry the cwd's git checkout.
    public var carriesCode: Bool

    /// Creates a request.
    public init(
        sessionID: String,
        source: AgentMoveEndpoint,
        destination: AgentMoveEndpoint,
        localHome: String,
        carriesCode: Bool = true
    ) {
        self.sessionID = sessionID
        self.source = source
        self.destination = destination
        self.localHome = localHome
        self.carriesCode = carriesCode
    }
}

/// What happened to the cwd's code state.
public enum AgentMoveCodeOutcome: Sendable, Equatable {
    /// `--no-code` was passed.
    case skipped
    /// The cwd is not inside a git checkout; no files moved.
    case notGitCheckout(path: String)
    /// The checkout was carried.
    case synced(checkout: String, head: String, branch: String?, snapshot: String, addedWorktree: Bool)
}

/// The result of a completed move. The caller opens the resumed session.
public struct AgentMoveOutcome: Sendable, Equatable {
    /// The moved session id.
    public var sessionID: String
    /// The session cwd on the source.
    public var sourceWorkingDirectory: String
    /// The session cwd on the destination.
    public var destinationWorkingDirectory: String
    /// The destination transcript path.
    public var destinationTranscriptPath: String
    /// The home path mapping that was applied.
    public var pathMap: AgentMovePathMap
    /// What happened to the code state.
    public var code: AgentMoveCodeOutcome

    /// Creates an outcome.
    public init(
        sessionID: String,
        sourceWorkingDirectory: String,
        destinationWorkingDirectory: String,
        destinationTranscriptPath: String,
        pathMap: AgentMovePathMap,
        code: AgentMoveCodeOutcome
    ) {
        self.sessionID = sessionID
        self.sourceWorkingDirectory = sourceWorkingDirectory
        self.destinationWorkingDirectory = destinationWorkingDirectory
        self.destinationTranscriptPath = destinationTranscriptPath
        self.pathMap = pathMap
        self.code = code
    }
}

/// Progress reported while a move runs, before the outcome.
public enum AgentMoveProgress: Sendable, Equatable {
    /// A worktree was added on the destination for the session cwd.
    case addingWorktree(path: String)
}

/// Why a move was refused or failed. Every refusal happens before session data
/// changes on the destination, except ``copyFailed(path:detail:)``.
public enum AgentMoveError: Error, Sendable, Equatable {
    /// The session id is not a UUID.
    case invalidSessionID(String)
    /// Source and destination are the same machine.
    case sameEndpoint
    /// Neither side is this machine; v1 moves always go through the local machine.
    case unsupportedRoute
    /// The SSH destination has values `rsync -e` cannot carry.
    case unsupportedSSHTarget(String)
    /// The host could not be reached.
    case unreachable(host: String, detail: String)
    /// A Claude process for this session is running on the source.
    case liveOnSource(host: String)
    /// A Claude process for this session is running on the destination.
    case liveOnDestination(host: String)
    /// No transcript for the session on the source.
    case transcriptNotFound(host: String)
    /// The transcript records no cwd.
    case workingDirectoryUnknown
    /// The path contains whitespace, which the transfer does not support.
    case unsupportedPath(String)
    /// No checkout at the path and no repository to add a worktree from.
    case destinationRepositoryMissing(checkout: String, repository: String)
    /// `git worktree add` failed on the destination.
    case worktreeAddFailed(path: String, detail: String)
    /// The destination checkout has changes that did not come from this session.
    case destinationCheckoutDirty(path: String)
    /// The destination branch has commits the source HEAD does not contain.
    case destinationBranchDiverged(branch: String)
    /// A git step failed.
    case gitFailed(step: String, detail: String)
    /// The session cwd does not exist on the destination.
    case destinationWorkingDirectoryMissing(String)
    /// The destination transcript has turns the source lacks.
    case destinationTranscriptNewer
    /// The transcripts are not prefixes of each other.
    case transcriptsDiverged
    /// Copying session data at `path` failed.
    case copyFailed(path: String, detail: String)
}
