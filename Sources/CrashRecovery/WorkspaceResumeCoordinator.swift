import Foundation

/// A live workspace surface that can be resumed. Abstracts the parts of
/// `Workspace`/`TerminalPanel` the coordinator needs, so the orchestration is
/// unit-testable with a fake and the real wiring stays thin glue.
@MainActor
protocol ResumableWorkspaceSurface: AnyObject {
    /// The workspace's display name (auto- or user-set), the breadcrumb anchor.
    var resumeWorkspaceName: String { get }
    /// The backing agent kind, if known.
    var resumeAgentKind: RestorableAgentKind? { get }
    /// A non-nil/non-empty token when there is a resume command to run (cmux's
    /// resume binding carries the command rather than a bare session id).
    var resumeSessionToken: String? { get }
    /// Whether the resume binding is proven (agent-hook/cli) vs. merely
    /// process-detected/unproven.
    var isResumeBindingProven: Bool { get }
    /// Whether an agent is already running in the surface (manual action on a
    /// live agent) vs. needing a native resume launch first.
    var isAgentLive: Bool { get }

    /// Re-run the agent's stored resume command to bring the agent back.
    func runNativeResume()
    /// Deliver the breadcrumb to the agent. Cold-restored surfaces must queue this
    /// behind an observed native resume command rather than plain terminal
    /// readiness.
    func deliverResumeBreadcrumb(_ text: String)

    // MARK: Verification facts (U10/U11) — additive over the v1 surface.
    //
    // These let the coordinator's verification-gated `recover(_:)` path build the
    // `ResumeBindingFacts` the gate needs. They carry protocol-extension defaults
    // so existing conformers (and the v1 fakes) keep compiling; the real
    // `Workspace` overrides them with the on-disk adapter (transcript existence at
    // this window's cwd vs. elsewhere). The defaults are deliberately
    // conservative — a conformer that has not wired the adapter reports "no
    // transcript verified", so `recover(_:)` routes to honest recovery rather
    // than ever auto-resuming an unverified binding.

    /// The working directory this surface is restoring into (honest-prompt scope).
    var resumeCwd: String? { get }
    /// The verified transcript path, when the binding carried one.
    var resumeTranscriptPath: String? { get }
    /// Whether a native resume command can be constructed for this binding.
    var resumeCommandConstructable: Bool { get }
    /// Whether the session's transcript exists on disk at *this window's* cwd.
    var transcriptExistsAtWindowCwd: Bool { get }
    /// Whether the session's transcript exists under some *other* cwd.
    var transcriptExistsElsewhere: Bool { get }

    /// Deliver the honest, cwd-scoped recovery prompt to the (fresh) agent —
    /// immediately if live, else when the surface becomes ready. Used only on the
    /// unverified branch; never paired with a native resume.
    func deliverHonestRecoveryPrompt(_ text: String)
    /// Whether the surface has an agent-owned input channel for the honest prompt.
    /// This must be stricter than "terminal surface exists": a plain shell must
    /// never receive prose intended for an agent.
    var canDeliverHonestRecoveryPrompt: Bool { get }
}

extension ResumableWorkspaceSurface {
    var resumeCwd: String? { nil }
    var resumeTranscriptPath: String? { nil }
    /// A resume command is constructable when a non-empty resume token exists.
    var resumeCommandConstructable: Bool {
        (resumeSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    var transcriptExistsAtWindowCwd: Bool { false }
    var transcriptExistsElsewhere: Bool { false }
    /// Default: route the honest prompt through the same deliver-when-ready path
    /// as the breadcrumb. Conformers that distinguish the two can override.
    func deliverHonestRecoveryPrompt(_ text: String) { deliverResumeBreadcrumb(text) }
    var canDeliverHonestRecoveryPrompt: Bool { isAgentLive }
}

/// The outcome of attempting to resume a single workspace.
enum ResumeOutcome: Equatable, Sendable {
    case resumed(deliveredBreadcrumb: Bool)
    case skipped(ResumeBreadcrumbBuilder.SkipReason)
}

/// The outcome of the verification-gated recovery path (U11). Unlike
/// `ResumeOutcome` there is no "skip": an unverified binding is not silently
/// abandoned, it is routed to honest agent-first recovery.
enum RecoveryPerformed: Equatable, Sendable {
    /// The binding verified: native resume ran (if needed) and the breadcrumb
    /// was delivered (when injection is on).
    case resumed(deliveredBreadcrumb: Bool)
    /// The binding could not be verified. The honest cwd-scoped prompt is
    /// delivered only when an agent-owned input channel is already available;
    /// otherwise the prompt is withheld so prose is never typed into a shell.
    /// `reason` is carried for logging.
    case honestRecovery(reason: UnverifiedReason, deliveredPrompt: Bool)
}

/// Shared orchestration for "pick up where we left off", used by both the
/// crash-recovery offer (U5) and the manual per-workspace action (U6). It maps a
/// live surface into the pure `WorkspaceResumePlanner` decision, then performs
/// the native resume (when needed) and breadcrumb delivery. The decision logic
/// lives in the planner; this layer is the thin, MainActor performer.
@MainActor
struct WorkspaceResumeCoordinator {
    let planner: WorkspaceResumePlanner
    /// Verification-gated router for the default silent restore path (U11).
    let router: RecoveryRouter

    init(injectBreadcrumb: Bool) {
        self.planner = WorkspaceResumePlanner(injectBreadcrumb: injectBreadcrumb)
        self.router = RecoveryRouter(injectBreadcrumb: injectBreadcrumb)
    }

    /// Build the planner context from a live surface.
    func context(for surface: ResumableWorkspaceSurface) -> ResumeWorkspaceContext {
        ResumeWorkspaceContext(
            workspaceName: surface.resumeWorkspaceName,
            agentKind: surface.resumeAgentKind,
            sessionId: surface.resumeSessionToken,
            isResumeBindingProven: surface.isResumeBindingProven
        )
    }

    /// Decide without performing — used to enable/disable the manual action.
    func canResume(_ surface: ResumableWorkspaceSurface) -> Bool {
        guard case .resume = planner.decide(context(for: surface)) else { return false }
        return router.wouldAutoResume(bindingFacts(for: surface))
    }

    /// Resume the surface: native resume if the agent isn't live, then deliver the
    /// breadcrumb (if injection is on). Never clobbers — a non-resumable surface
    /// is left untouched and the reason returned.
    @discardableResult
    func resume(_ surface: ResumableWorkspaceSurface) -> ResumeOutcome {
        switch planner.decide(context(for: surface)) {
        case .skip(let reason):
            return .skipped(reason)
        case .resume:
            switch router.route(bindingFacts(for: surface), context: recoveryContext(for: surface)) {
            case .honestRecovery(_, let reason):
                return .skipped(Self.skipReason(for: reason))
            case .resumeVerified(let breadcrumb):
                return performVerifiedResume(surface, breadcrumb: breadcrumb)
            }
        }
    }

    private static func skipReason(for reason: UnverifiedReason) -> ResumeBreadcrumbBuilder.SkipReason {
        switch reason {
        case .noSessionId:
            return .noSessionId
        case .unsupportedAgent(let kind):
            return .unsupportedAgent(kind)
        case .noBinding, .resumeUnavailable, .transcriptMissing, .cwdMismatch:
            return .unprovenSession
        }
    }

    func performVerifiedResume(_ surface: ResumableWorkspaceSurface, breadcrumb: String?) -> ResumeOutcome {
        let deliveredBreadcrumb = performVerifiedResumeDelivery(surface, breadcrumb: breadcrumb)
        return .resumed(deliveredBreadcrumb: deliveredBreadcrumb)
    }

    private func performVerifiedRecovery(_ surface: ResumableWorkspaceSurface, breadcrumb: String?) -> RecoveryPerformed {
        let deliveredBreadcrumb = performVerifiedResumeDelivery(surface, breadcrumb: breadcrumb)
        return .resumed(deliveredBreadcrumb: deliveredBreadcrumb)
    }

    private func performVerifiedResumeDelivery(_ surface: ResumableWorkspaceSurface, breadcrumb: String?) -> Bool {
        if !surface.isAgentLive {
            surface.runNativeResume()
        }
        if let breadcrumb {
            surface.deliverResumeBreadcrumb(breadcrumb)
        }
        return breadcrumb != nil
    }

    // MARK: - Verification-gated recovery (U11/R14)

    /// Build the verifiable binding facts from a live surface.
    func bindingFacts(for surface: ResumableWorkspaceSurface) -> ResumeBindingFacts {
        let hasToken = surface.resumeSessionToken?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return ResumeBindingFacts(
            hasBinding: surface.resumeAgentKind != nil || hasToken,
            agentKind: surface.resumeAgentKind,
            sessionId: Self.bareSessionId(from: surface.resumeSessionToken),
            resumeCommandConstructable: surface.resumeCommandConstructable,
            transcriptExistsAtWindowCwd: surface.transcriptExistsAtWindowCwd,
            transcriptExistsElsewhere: surface.transcriptExistsElsewhere
        )
    }

    /// Return the bare session id from either the modern checkpoint id or a
    /// legacy resume command token such as `claude --resume <id>`.
    nonisolated static func bareSessionId(from token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }

        let words = trimmed.split { $0.isWhitespace }.map { stripShellQuotes(String($0)) }
        for (index, word) in words.enumerated() {
            if word == "--resume" || word == "-r" {
                let next = words.index(after: index)
                return next < words.endIndex ? nonEmpty(words[next]) : nil
            }
            if word.hasPrefix("--resume=") {
                return nonEmpty(stripShellQuotes(String(word.dropFirst("--resume=".count))))
            }
            if word == "resume",
               index > words.startIndex,
               isCodexExecutable(words[words.index(before: index)]) {
                let next = words.index(after: index)
                return next < words.endIndex ? nonEmpty(words[next]) : nil
            }
        }
        return nonEmpty(stripShellQuotes(trimmed))
    }

    nonisolated private static func isCodexExecutable(_ word: String) -> Bool {
        let leaf = (word as NSString).lastPathComponent
        return leaf == "codex"
    }

    nonisolated private static func stripShellQuotes(_ value: String) -> String {
        var result = value
        while result.count >= 2 {
            let first = result.first
            let last = result.last
            if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
                result.removeFirst()
                result.removeLast()
            } else {
                break
            }
        }
        return result
    }

    nonisolated private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Build the window-scoped recovery context from a live surface.
    func recoveryContext(for surface: ResumableWorkspaceSurface) -> RecoveryContext {
        RecoveryContext(
            workspaceName: surface.resumeWorkspaceName,
            cwd: surface.resumeCwd,
            transcriptPath: surface.resumeTranscriptPath
        )
    }

    /// The verification-gated recovery entry point for the silent restore path
    /// (R14/R17): verify the binding, then either resume the exact session +
    /// deliver the privacy-safe breadcrumb, or deliver the honest
    /// cwd-scoped recovery prompt and resume nothing. Never auto-resumes an
    /// unverified binding; never enumerates sessions. Distinct from `resume(_:)`,
    /// which backs the opt-in offer (U5) and manual action (U6) under the v1
    /// proven-binding rule.
    ///
    /// Calling this from the live restore path, and having the real `Workspace`
    /// supply on-disk verification facts (instead of the conservative
    /// honest-recovery defaults), is the U14 live-validation step.
    @discardableResult
    func recover(_ surface: ResumableWorkspaceSurface) -> RecoveryPerformed {
        let facts = bindingFacts(for: surface)
        switch router.route(facts, context: recoveryContext(for: surface)) {
        case .resumeVerified(let breadcrumb):
            return performVerifiedRecovery(surface, breadcrumb: breadcrumb)
        case .honestRecovery(let prompt, let reason):
            let deliveredPrompt = performHonestRecovery(surface, prompt: prompt)
            return .honestRecovery(reason: reason, deliveredPrompt: deliveredPrompt)
        }
    }

    private func performHonestRecovery(_ surface: ResumableWorkspaceSurface, prompt: String) -> Bool {
        guard surface.canDeliverHonestRecoveryPrompt else { return false }
        surface.deliverHonestRecoveryPrompt(prompt)
        return true
    }
}
