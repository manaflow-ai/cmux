import CmuxSurfaceCatalogModel
import Foundation

/// What the Cloud tree says about a terminal whose run ended badly, and what
/// it offers to do about it. Pure: the row, its tooltip, and the exit popover
/// all read this one type, so a failed agent run reads the same everywhere.
///
/// A failed run whose tab is gone used to vanish with its pane. It now keeps a
/// pool row (amber attention, like an agent waiting on the user) with its
/// exit status; clicking the row shows the run's last lines and, when the
/// output names a recognizable cause, the fix.
struct CloudTerminalExitPresentation: Equatable {
    /// A cause recognized in the run's last lines, with a one-click fix.
    enum Diagnosis: Equatable {
        /// The agent rejected or could not find its provider credentials.
        case missingAPIKey
    }

    let exit: SurfaceTerminalExit

    /// How long a failed, tabless run stays listed. The daemon keeps the
    /// record indefinitely and nothing can close it, so it ages out: a failed
    /// run is news, not history. The provider applies the same window (and a
    /// per-machine cap) to every publish; the tree re-checks it for rows that
    /// age out between publishes.
    static let retention: TimeInterval = SurfaceResource.failedExitRetentionWindow

    /// Short status for the row's detail column: "exit 1", "signal 9".
    var shortStatus: String {
        switch exit.kind {
        case .exit:
            return String(format: String(localized: "cloudTree.terminal.exit.short.code", defaultValue: "exit %d"), exit.code ?? 0)
        case .signal:
            return String(format: String(localized: "cloudTree.terminal.exit.short.signal", defaultValue: "signal %d"), exit.signal ?? 0)
        case .unknown:
            return String(localized: "cloudTree.terminal.exit.short.unknown", defaultValue: "failed")
        }
    }

    /// The sentence a person reads: "Exited with code 1".
    var headline: String {
        switch exit.kind {
        case .exit:
            return String(format: String(localized: "cloudTree.terminal.exit.headline.code", defaultValue: "Exited with code %d"), exit.code ?? 0)
        case .signal:
            return String(format: String(localized: "cloudTree.terminal.exit.headline.signal", defaultValue: "Ended by signal %d"), exit.signal ?? 0)
        case .unknown:
            if let reason = exit.reason {
                return String(format: String(localized: "cloudTree.terminal.exit.headline.unknownReason", defaultValue: "Ended: %@"), reason)
            }
            return String(localized: "cloudTree.terminal.exit.headline.unknown", defaultValue: "Ended unexpectedly")
        }
    }

    /// The row tooltip: what happened and what a click does.
    var help: String {
        headline + "\n" + String(localized: "cloudTree.terminal.exit.help", defaultValue: "Click to see its last lines.")
    }

    /// The one failure predicate for a terminal: its process exited badly
    /// (`SurfaceTerminalExit.isFailure`), or its agent reported an error this
    /// Mac has not read yet. The second case matters because `cmux vm clone`
    /// keeps a login shell after the agent, so a failed agent leaves a live
    /// terminal whose own exit never shows the failure. The tree's terminal
    /// row, its workspace row and the Get started checklist all read this.
    /// - Parameters:
    ///   - resource: The terminal.
    ///   - hasUnreadFailureNotification: Its machine holds an unread
    ///     notification for it that reports a failure.
    /// - Returns: Whether the terminal reports a failed run.
    static func reportsFailure(_ resource: SurfaceResource, hasUnreadFailureNotification: Bool) -> Bool {
        guard resource.kind == .terminal else { return false }
        if hasUnreadFailureNotification { return true }
        return resource.lifecycle == .exited && resource.exit?.isFailure == true
    }

    /// The tooltip line for a live terminal whose agent reported an error.
    static var reportedErrorHelp: String {
        String(
            localized: "cloudTree.terminal.agentError.help",
            defaultValue: "The agent reported an error. Open the terminal to see what happened."
        )
    }

    /// Whether a failed tabless run is still recent enough to list.
    static func isListed(_ resource: SurfaceResource, now: Date) -> Bool {
        // A run with no exit time is aged by the provider from when it was first seen.
        guard resource.exit?.exitedAt != nil else { return true }
        return SurfaceResource.isWithinFailedExitWindow(resource, now: now)
    }

    /// The last `limit` non-blank-trailing lines of the run's final output.
    static func lastLines(of text: String, limit: Int = 12) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        return lines.suffix(limit).joined(separator: "\n")
    }

    /// Phrases agent CLIs print when their provider key is missing, invalid,
    /// or not logged in (Claude Code, Codex, Gemini, OpenCode, Anthropic and
    /// OpenAI SDK errors). Lowercased; matched as substrings.
    private static let credentialPhrases = [
        "invalid api key",
        "invalid x-api-key",
        "incorrect api key",
        "api key not valid",
        "invalid_api_key",
        "authentication_error",
        "missing api key",
        "no api key",
        "api key is required",
        "api_key environment variable",
        "please run /login",
        "not logged in",
        "401 unauthorized",
        "status code 401",
    ]

    /// A recognized cause in the run's last lines, or nil.
    static func diagnosis(lastLines text: String) -> Diagnosis? {
        let lowered = text.lowercased()
        if credentialPhrases.contains(where: lowered.contains) { return .missingAPIKey }
        return nil
    }

    static func fixTitle(_ diagnosis: Diagnosis) -> String {
        switch diagnosis {
        case .missingAPIKey:
            return String(localized: "cloudTree.terminal.exit.fix.addAPIKey", defaultValue: "Add API Key\u{2026}")
        }
    }

    static func diagnosisExplanation(_ diagnosis: Diagnosis) -> String {
        switch diagnosis {
        case .missingAPIKey:
            return String(localized: "cloudTree.terminal.exit.fix.addAPIKey.explanation", defaultValue: "The agent could not authenticate. Add its API key to Cloud Secrets and start it again.")
        }
    }
}
