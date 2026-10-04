public import Foundation

/// The REPL sessions' domain policies as the navigation checks read them.
///
/// Models the driver as it is: the checks get a policy only once its
/// content rules are installed, and nothing waits for them.
public final class BrowserReplPolicyBoard: @unchecked Sendable {
    public enum RuleState: Equatable, Sendable {
        case installed
        case pending
        case failed(String)
    }

    private let lock = NSLock()
    private var pending: [String: (policy: BrowserReplDomainPolicy, generation: Int)] = [:]
    private var installed: [String: BrowserReplDomainPolicy] = [:]
    private var nextGeneration = 0

    public init() {}

    @discardableResult
    public func publish(_ policy: BrowserReplDomainPolicy, sessionID: String) -> Int {
        lock.withLock {
            nextGeneration += 1
            pending[sessionID] = (policy, nextGeneration)
            return nextGeneration
        }
    }

    public func policy(for sessionID: String) -> BrowserReplDomainPolicy? {
        lock.withLock { installed[sessionID] }
    }

    public func ruleState(for sessionID: String) -> RuleState {
        .installed
    }

    @MainActor
    public func whenRulesSettle(sessionID: String, _ body: @escaping @MainActor (RuleState) -> Void) {
        body(.installed)
    }

    @MainActor
    public func rulesInstalled(sessionID: String, generation: Int) {
        lock.withLock {
            guard let entry = pending[sessionID], entry.generation == generation else { return }
            installed[sessionID] = entry.policy.isActive ? entry.policy : nil
        }
    }

    @MainActor
    public func rulesFailed(sessionID: String, generation: Int, reason: String) {}

    @MainActor
    public func removeSession(_ sessionID: String) {
        lock.withLock {
            pending.removeValue(forKey: sessionID)
            installed.removeValue(forKey: sessionID)
        }
    }
}
