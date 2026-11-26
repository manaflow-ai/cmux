/// Decides when a Ghostty config load should surface its diagnostics.
///
/// Every reload (file edits, appearance changes, font zoom) re-reads the same
/// config, so an unfixed error would reappear constantly. The policy presents
/// a set of errors once, stays quiet while the same set persists, presents
/// again when the set changes, and resets after a clean load so a
/// reintroduced error is reported again. Diagnostics from cmux's own inline
/// fragments and about cmux-owned keys (``GhosttyConfig/cmuxOwnedKeys``) are
/// not user-actionable and are dropped.
///
/// ```swift
/// var policy = GhosttyConfigDiagnosticsNoticePolicy()
/// switch policy.decision(forMessages: messages) {
/// case .present(let notice): presenter.show(notice)
/// case .dismiss: presenter.hide()
/// case .unchanged: break
/// }
/// ```
public struct GhosttyConfigDiagnosticsNoticePolicy: Sendable {
    /// The most diagnostics a notice lists; the rest are summarized as a count.
    public static let maximumListedDiagnostics = 3

    private var lastPresented: Set<GhosttyConfigDiagnostic>?

    /// Creates a policy that has presented nothing.
    public init() {}

    /// Records one config load's raw diagnostic messages and returns what to
    /// do with the notice.
    ///
    /// - Parameter messages: Messages in Ghostty's order, as returned by
    ///   `ghostty_config_get_diagnostic`.
    /// - Returns: The notice decision for this load.
    public mutating func decision(forMessages messages: [String]) -> GhosttyConfigDiagnosticsNoticeDecision {
        let diagnostics = Self.userFacingDiagnostics(fromMessages: messages)
        let current = Set(diagnostics)

        guard !diagnostics.isEmpty else {
            guard lastPresented != nil else { return .unchanged }
            lastPresented = nil
            return .dismiss
        }
        guard current != lastPresented else { return .unchanged }
        lastPresented = current
        return .present(
            GhosttyConfigDiagnosticsNotice(
                listedDiagnostics: Array(diagnostics.prefix(Self.maximumListedDiagnostics)),
                totalCount: diagnostics.count
            )
        )
    }

    /// The diagnostics a notice should report: parsed, deduplicated, in
    /// Ghostty's order, without empty messages, cmux's own inline fragments,
    /// or cmux-owned keys Ghostty does not know.
    ///
    /// - Parameter messages: Raw messages from `ghostty_config_get_diagnostic`.
    /// - Returns: The user-actionable diagnostics.
    public static func userFacingDiagnostics(fromMessages messages: [String]) -> [GhosttyConfigDiagnostic] {
        var seen = Set<GhosttyConfigDiagnostic>()
        var diagnostics: [GhosttyConfigDiagnostic] = []
        for message in messages {
            let diagnostic = GhosttyConfigDiagnostic(message: message)
            guard !diagnostic.message.isEmpty,
                  !diagnostic.isFromCmuxInlineConfig,
                  !diagnostic.isForCmuxOwnedKey,
                  seen.insert(diagnostic).inserted else { continue }
            diagnostics.append(diagnostic)
        }
        return diagnostics
    }
}
