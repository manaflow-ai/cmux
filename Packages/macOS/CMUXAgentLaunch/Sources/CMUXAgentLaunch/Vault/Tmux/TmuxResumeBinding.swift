public import Foundation

/// A resolved, resumable tmux-attach binding produced by
/// ``TmuxResumeBindingResolver``.
///
/// This carries the exact fields the legacy `TmuxResumeParser.binding(...)`
/// placed on the app-side `SurfaceResumeBindingSnapshot`, so the app can map
/// this value into that snapshot one-to-one. It is a plain `Sendable` value so
/// the resolver stays free of the app's snapshot type.
public struct TmuxResumeBinding: Sendable, Equatable {
    /// The binding's display name (e.g. `tmux <session>` or `tmux`).
    public let name: String

    /// The binding kind, always `tmux`.
    public let kind: String

    /// The rebuilt, shell-single-quoted resume command (a `tmux ... attach`).
    public let command: String

    /// The resume working directory, if resolvable from the environment.
    public let cwd: String?

    /// The checkpoint identifier (the tmux session name), if any.
    public let checkpointId: String?

    /// The binding source, always `process-detected`.
    public let source: String

    /// The resume environment overrides (e.g. `TMUX_TMPDIR`), if any.
    public let environment: [String: String]?

    /// Whether automatic resume is requested (always `true`).
    public let autoResume: Bool

    /// The capture timestamp (seconds since 1970).
    public let updatedAt: TimeInterval

    /// Creates a resolved tmux resume binding.
    ///
    /// - Parameters:
    ///   - name: The binding's display name.
    ///   - kind: The binding kind.
    ///   - command: The rebuilt resume command.
    ///   - cwd: The resume working directory.
    ///   - checkpointId: The checkpoint identifier (tmux session name).
    ///   - source: The binding source.
    ///   - environment: The resume environment overrides.
    ///   - autoResume: Whether automatic resume is requested.
    ///   - updatedAt: The capture timestamp.
    public init(
        name: String,
        kind: String,
        command: String,
        cwd: String?,
        checkpointId: String?,
        source: String,
        environment: [String: String]?,
        autoResume: Bool,
        updatedAt: TimeInterval
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.cwd = cwd
        self.checkpointId = checkpointId
        self.source = source
        self.environment = environment
        self.autoResume = autoResume
        self.updatedAt = updatedAt
    }
}
