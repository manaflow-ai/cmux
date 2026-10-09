public import Foundation

/// The has-data rule of the first run (plans/cmux-next/onboarding.md 4).
/// The first-run page shows only when every check passes; any data of the
/// user's own ends onboarding silently. Claude Code, Codex, Pi and OpenCode
/// history on disk is not an input: it is detection input for the page
/// (projects, signed-in harnesses), and a new cmux user with that history is
/// the main target. Pure: the caller gathers the facts once per launch,
/// after the daemon snapshot (`WindowManager.restore`).
public nonisolated struct FirstRunGate: Sendable, Equatable {
    /// Where cmux-next.json stood before this launch seeded it
    /// (`CmuxConfigFile.prepareDefaultURL`).
    public enum ConfigOrigin: String, Sendable, Equatable {
        /// No file, and nothing to seed it from.
        case absent
        /// A file with an empty object (comments allowed) or no text.
        case empty
        /// A file with settings in it.
        case settings
        /// This launch copies classic cmux's `cmux.json` into it.
        case seededFromClassic
    }

    /// The check that found data of the user's own.
    public enum Check: String, Sendable, Equatable {
        /// The tree had a workspace of the user's own at this launch.
        case workspaces
        /// acpmux history has agent sessions.
        case agentSessions
        /// cmux-next.json has settings or was seeded from classic cmux.
        case config
        /// Classic cmux saved a session snapshot.
        case classicSnapshot
    }

    public enum Decision: Equatable, Sendable {
        /// A fresh user: the launch's New Tab page is the first run.
        case firstRun
        /// Onboarding was finished, skipped or decided before: nothing.
        case decided
        /// Data found: onboarding ends now (`reason: existing-data`), nothing shows.
        case existingData(Check)
    }

    /// `FirstWorkspace.isNeeded` at this launch: no workspace of the user's own.
    public var firstWorkspaceNeeded: Bool
    /// Sessions in acpmux history.
    public var agentSessions: Int
    public var config: ConfigOrigin
    /// Classic cmux's session snapshot exists (`ClassicSessionImporter.hasSnapshot`).
    public var classicSnapshot: Bool

    public init(firstWorkspaceNeeded: Bool, agentSessions: Int, config: ConfigOrigin, classicSnapshot: Bool) {
        self.firstWorkspaceNeeded = firstWorkspaceNeeded
        self.agentSessions = agentSessions
        self.config = config
        self.classicSnapshot = classicSnapshot
    }

    /// The launch's decision, given what the state file says about this
    /// launch (`OnboardingStateFile.takeLaunchShow`).
    public func decide(launch: OnboardingStateFile.LaunchShow) -> Decision {
        guard launch != .none else { return .decided }
        if !firstWorkspaceNeeded { return .existingData(.workspaces) }
        if agentSessions > 0 { return .existingData(.agentSessions) }
        switch config {
        case .settings, .seededFromClassic: return .existingData(.config)
        case .absent, .empty: break
        }
        if classicSnapshot { return .existingData(.classicSnapshot) }
        return .firstRun
    }
}

extension OnboardingStateFile {
    /// The launch's first-run decision in one call (run it on
    /// `OnboardingStateQueue`): takes the launch, and on existing data marks
    /// onboarding done with `reason: existing-data` in the same operation.
    public nonisolated func decideFirstRun(_ gate: FirstRunGate, now: Date = Date()) -> FirstRunGate.Decision {
        let decision = gate.decide(launch: takeLaunchShow(now: now))
        if case .existingData = decision { try? markDone(completed: false, reason: .existingData, now: now) }
        return decision
    }
}
