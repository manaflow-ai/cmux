import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let projectRootPath: String
    let worktreePath: String
    let branchName: String
    let workspaceTitle: String
    let createdHead: String
    let generatedArtifactRelativePath: String
    let generatedArtifactContents: Data
    /// Filesystem identity captured immediately after `git worktree add`.
    /// Rollback refuses to touch a path whose checkout was replaced.
    /// No inline default: newer Swift toolchains (6.3+) reject assigning an
    /// already-defaulted `let` in the explicit initializer below, which keeps
    /// these labels available on every toolchain via its defaulted parameters.
    let worktreeDeviceID: UInt64?
    let worktreeFileID: UInt64?
    /// A convenience command (e.g. a sample dev-server launcher) that should run
    /// inside the new workspace's interactive shell. This is *setup*, never the
    /// workspace's primary process.
    let setupCommand: String

    /// Keeps the optional filesystem identity labels available while preserving
    /// default-`nil` call sites without preinitializing immutable properties.
    init(
        projectRootPath: String,
        worktreePath: String,
        branchName: String,
        workspaceTitle: String,
        createdHead: String,
        generatedArtifactRelativePath: String,
        generatedArtifactContents: Data,
        worktreeDeviceID: UInt64? = nil,
        worktreeFileID: UInt64? = nil,
        setupCommand: String
    ) {
        self.projectRootPath = projectRootPath
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.workspaceTitle = workspaceTitle
        self.createdHead = createdHead
        self.generatedArtifactRelativePath = generatedArtifactRelativePath
        self.generatedArtifactContents = generatedArtifactContents
        self.worktreeDeviceID = worktreeDeviceID
        self.worktreeFileID = worktreeFileID
        self.setupCommand = setupCommand
    }
}
