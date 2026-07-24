/// Extends worktree setup after Git add and built-in submodule initialization.
///
/// The separate `.worktreeinclude` feature plugs into this seam without making
/// copied files part of worktree identity or Git lifecycle state.
public protocol WorktreePostCreateHook: Sendable {
    /// Performs caller-owned post-create work.
    /// - Parameters:
    ///   - context: The immutable create result and base ref.
    ///   - host: The same execution host used for the Git operation.
    /// - Throws: A hook-specific error when the created worktree needs attention.
    func run(
        context: WorktreePostCreateContext,
        on host: any WorktreeExecutionHost
    ) async throws
}
