import CmuxNextHomeEngine
import Foundation

/// What this Mac's Chief home copied into which Hosted Chief, and for which
/// account (app-local; the copy steps are idempotent, so a lost record only
/// repeats skips).
@MainActor
struct HostedChiefLedger {
    enum Step: String { case history, memory, memoryStarted, brain }

    let session: String
    var defaults: UserDefaults = .standard

    /// The UserDefaults keys (Rust `chief_home.ledger_keys`). Without the rules nothing is read or written:
    /// the steps are idempotent, so the copy only repeats.
    private struct Keys: Decodable {
        let account: String
        let history: String
        let memory: String
        let memoryStarted: String
        let brain: String
        let failures: String

        func key(_ step: Step) -> String {
            switch step {
            case .history: history
            case .memory: memory
            case .memoryStarted: memoryStarted
            case .brain: brain
            }
        }
    }

    private func keys(chief: String) -> Keys? {
        struct Request: Encodable { let session: String; let chief: String }
        return try? ChiefHomeRules().call("ledger_keys", Request(session: session, chief: chief))
    }

    /// The account this Chief home was copied for (another account does not copy it).
    var account: String? { keys(chief: "").flatMap { defaults.string(forKey: $0.account) } }

    func claim(account: String) {
        if self.account == nil, let keys = keys(chief: "") { defaults.set(account, forKey: keys.account) }
    }

    func done(_ step: Step, chief: String) -> Bool { keys(chief: chief).map { defaults.bool(forKey: $0.key(step)) } ?? false }

    func mark(_ step: Step, chief: String) {
        if let keys = keys(chief: chief) { defaults.set(true, forKey: keys.key(step)) }
    }

    /// Copy runs that failed in a row; after ``maxFailures`` the copy gives up (logged).
    static let maxFailures = 3
    func failed(chief: String) -> Int { keys(chief: chief).map { defaults.integer(forKey: $0.failures) } ?? 0 }
    func recordFailure(chief: String) {
        if let keys = keys(chief: chief) { defaults.set(defaults.integer(forKey: keys.failures) + 1, forKey: keys.failures) }
    }
    func clearFailures(chief: String) {
        if let keys = keys(chief: chief) { defaults.removeObject(forKey: keys.failures) }
    }

    /// The server refused the content (counts toward giving up); a network, rate, server or sign-in error does not
    /// (an expired token must not end the copy with nothing copied). Rust `chief_home.ledger_is_refusal`; without
    /// the rules, not a refusal.
    static func isRefusal(_ error: any Error) -> Bool {
        guard case let HostedChiefError.owner(code, _) = error else { return false }
        struct Request: Encodable { let ownerCode: String }
        struct Reply: Decodable { let refusal: Bool }
        return ((try? ChiefHomeRules().call("ledger_is_refusal", Request(ownerCode: code))) as Reply?)?.refusal ?? false
    }

    /// The import source's host: this Mac's Chief home session, as a token (ASCII 0x21-0x7e, at most 128;
    /// Rust `chief_home.ledger_host`, `mac-` alone without the rules).
    static func host(session: String) -> String {
        struct Request: Encodable { let session: String }
        struct Reply: Decodable { let host: String }
        return ((try? ChiefHomeRules().call("ledger_host", Request(session: session))) as Reply?)?.host ?? "mac-"
    }
}
