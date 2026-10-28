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

    /// Runs `script` in `browser`'s main frame (`world` "" = the page's world) for a caller in a
    /// synchronous turn (an event handler): `done` runs in the turn that delivers the answer, or with
    /// nil when the shim cannot evaluate, the browser closes, or a later call takes the slot. One at
    /// a time, so nothing waits on a timer: the latest question is the only one worth answering (a
    /// force click's Look Up, task p01-process-054).
    func evaluateLatest(_ browser: Int32, world: String, script: String, done: @escaping (CEFEvaluationResult?) -> Void) {
        latestEvaluation.take()?.done(nil)
        guard let tabEvaluate = shim?.tabEvaluate else { return done(nil) }
        let token = nextEvaluation
        nextEvaluation = nextEvaluation == .max ? 1 : nextEvaluation + 1
        latestEvaluation = (token, browser, done)
        if tabEvaluate(browser, token, world, script, 0) != 1, latestEvaluation?.token == token { latestEvaluation.take()?.done(nil) }
    }

    /// Runs `script` in `browser`'s main frame (`world` "" = the page's world) and keeps no answer: for a
    /// command whose value nobody reads (a menu's Copy). Its EVALUATE_RESULT finds no caller and is dropped.
    /// False when the shim cannot evaluate or refused the call.
    func perform(_ browser: Int32, world: String, script: String, userGesture: Bool) -> Bool {
        guard let tabEvaluate = shim?.tabEvaluate else { return false }
        let token = nextEvaluation
        nextEvaluation = nextEvaluation == .max ? 1 : nextEvaluation + 1
        return tabEvaluate(browser, token, world, script, userGesture ? 1 : 0) == 1
    }

    /// EVALUATE_RESULT: resumes its caller. An answer inside `tabEvaluate` (before the caller
    /// waits) is kept for it.
    func evaluationAnswered(token: Int32, _ result: CEFEvaluationResult) {
        if let latest = latestEvaluation, latest.token == token {
            latestEvaluation = nil
            return latest.done(result)
        }
        guard !evaluations.resolve(token, with: .success(result)), evaluationBrowsers[token] != nil else { return }
        earlyEvaluations[token] = result
    }

    /// The browser closed: its waiting evaluations fail.
    func failEvaluations(of browser: Int32) {
        if latestEvaluation?.browser == browser { latestEvaluation.take()?.done(nil) }
        evaluations.failAll(where: { evaluationBrowsers[$0] == browser }, with: BrowserTabError.closed)
    }
}
