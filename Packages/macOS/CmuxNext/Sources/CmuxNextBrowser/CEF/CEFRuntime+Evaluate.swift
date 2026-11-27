import Foundation

/// Script evaluation without a DevTools session (fork API 29, `CEFForkFeatures.rendererPaths`): a
/// tab that never opens DevTools has no DevTools agent, so Chrome's process reuse may share its
/// renderer with another tab of its site.
extension CEFRuntime {
    /// The longest wait for an evaluation's answer, as for a DevTools call.
    static let evaluateTimeout: Duration = CEFRuntime.devToolsTimeout

    /// Runs `script` in `browser`'s main frame (`world` "" = the page's world) and returns its answer.
    func evaluate(_ browser: Int32, world: String, script: String, userGesture: Bool,
                  timeout: Duration = CEFRuntime.evaluateTimeout) async throws -> CEFEvaluationResult {
        guard let tabEvaluate = shim?.tabEvaluate else { throw BrowserTabError.closed }
        let token = nextEvaluation
        nextEvaluation = nextEvaluation == .max ? 1 : nextEvaluation + 1
        evaluationBrowsers[token] = browser
        defer { evaluationBrowsers[token] = nil }
        guard tabEvaluate(browser, token, world, script, userGesture ? 1 : 0) == 1 else { throw BrowserTabError.closed }
        if let early = earlyEvaluations.removeValue(forKey: token) { return early }
        return try await evaluations.reply(for: token, timeout: timeout) { BrowserTabError.timedOut("evaluate (\(timeout))") }
    }

    /// EVALUATE_RESULT: resumes its caller. An answer inside `tabEvaluate` (before the caller
    /// waits) is kept for it.
    func evaluationAnswered(token: Int32, _ result: CEFEvaluationResult) {
        guard !evaluations.resolve(token, with: .success(result)), evaluationBrowsers[token] != nil else { return }
        earlyEvaluations[token] = result
    }

    /// The browser closed: its waiting evaluations fail.
    func failEvaluations(of browser: Int32) {
        evaluations.failAll(where: { evaluationBrowsers[$0] == browser }, with: BrowserTabError.closed)
    }
}
