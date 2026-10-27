import Foundation

/// Whether a page of a browser profile may open under the profile's own proxy (#24432).
enum CEFProfileProxyGate: Equatable {
    /// Direct, or Chromium applied the proxy.
    case open
    /// The shim refused the proxy, or Chromium did not apply it: no page of the profile opens (fail closed).
    case refused
    /// Host mode: the host's verdict is on its way (``CEFRuntime/whenProfileProxyApplied(_:then:)``).
    case waiting
}

/// Host mode: the host's verdict on one profile's proxy, from the REPLYs to the proxy and its state.
final class CEFProfileProxyCheck {
    fileprivate(set) var gate = CEFProfileProxyGate.waiting
    /// Called once with the verdict (true: open).
    fileprivate var waiters: [(Bool) -> Void] = []
}

/// A browser profile's own proxy in Chromium (#24432): the profile's
/// persistent request context uses it from its first request.
extension CEFRuntime {
    /// Hands `profile`'s proxy (or its clear) to the shim when it changed since the shim last took
    /// it, and says whether a page of the profile may open now. In process the shim answers in the
    /// call. In host mode the host's REPLYs answer later (`.waiting`) and a page of the profile waits
    /// for them (``whenProfileProxyApplied(_:then:)``): as fail closed as in process, where a refused
    /// proxy is handed over again at the next page.
    @discardableResult
    func applyProfileProxy(_ profile: BrowserProfileID) -> CEFProfileProxyGate {
        guard shim != nil else { return .refused }
        let changed = unappliedProfileProxies.remove(profile) != nil
        if !changed, let check = profileProxyChecks[profile] { return check.gate }
        let key = storage.contextKey(for: profile, machineKey: nil, offTheRecord: false)
        let proxy = profileProxies[profile]
        let stored: CEFShimAnswer<Int32> = if changed {
            sendAsync { shim in shim.setContextProxyServer(key, proxy?.chromiumServer ?? "", proxy?.chromiumBypassList ?? "") }
        } else {
            .now(1)
        }
        let state: CEFShimAnswer<Int32>? = if proxy == nil { nil } else { sendAsync { shim in shim.contextProxyState(key) } }
        switch (stored, state) {
        case (.now(let stored), .now(let state)?):
            return profileProxyGate(profile, stored: stored, state: state, changed: changed)
        case (.now(let stored), nil):
            return profileProxyGate(profile, stored: stored, state: nil, changed: changed)
        default:
            return checkProfileProxy(profile, stored: stored, state: state, changed: changed)
        }
    }

    /// Calls `then` with whether a page of `profile` may open: in this turn when
    /// ``applyProfileProxy(_:)`` decides it, else in the turn that brings the host's verdict.
    func whenProfileProxyApplied(_ profile: BrowserProfileID, then: @escaping (Bool) -> Void) {
        switch applyProfileProxy(profile) {
        case .open:
            then(true)
        case .refused:
            then(false)
        case .waiting:
            guard let check = profileProxyChecks[profile] else { return then(false) }
            check.waiters.append(then)
        }
    }

    /// The gate from the shim's answers: `stored` (1 took the proxy) and `state` (below 0: none applied).
    private func profileProxyGate(_ profile: BrowserProfileID, stored: Int32, state: Int32?, changed: Bool) -> CEFProfileProxyGate {
        guard stored == 1 else {
            logger.error("browser profile proxy refused by the shim")
            if changed { unappliedProfileProxies.insert(profile) }
            return .refused
        }
        return (state ?? 0) >= 0 ? .open : .refused
    }

    /// Host mode: takes both REPLYs (registered in this turn, as they must be) and keeps the verdict.
    /// A refusal, a failure or no answer within the reply deadline drops the check and refuses its
    /// waiting pages, so the next page of the profile asks again, as in process. ``hostGone()`` drops
    /// an open verdict too: it was the exited host's.
    private func checkProfileProxy(_ profile: BrowserProfileID, stored: CEFShimAnswer<Int32>, state: CEFShimAnswer<Int32>?,
                                   changed: Bool) -> CEFProfileProxyGate {
        let check = CEFProfileProxyCheck()
        profileProxyChecks[profile] = check
        var storedAnswer: Int32?
        var stateAnswer: Int32?
        var pending = state == nil ? 1 : 2
        let answered = { [weak self] in
            pending -= 1
            guard pending == 0, let self else { return }
            // A newer proxy of the profile (its own check) supersedes this one's side effects.
            let current = profileProxyChecks[profile] === check
            // No answer (a failure, the deadline, the host gone): the host may not hold the proxy.
            let unanswered = storedAnswer == nil || (state != nil && stateAnswer == nil)
            check.gate = profileProxyGate(profile, stored: storedAnswer ?? 0, state: state == nil ? nil : stateAnswer ?? -1,
                                          changed: changed && current)
            if check.gate == .refused, current {
                profileProxyChecks[profile] = nil
                if unanswered { unappliedProfileProxies.insert(profile) }
            }
            let waiters = check.waiters
            check.waiters.removeAll()
            for waiter in waiters { waiter(check.gate == .open) }
        }
        whenAnswered(stored, label: "profile proxy") { answer in
            storedAnswer = answer
            answered()
        }
        if let state {
            whenAnswered(state, label: "profile proxy state") { answer in
                stateAnswer = answer
                answered()
            }
        }
        return check.gate
    }
}
