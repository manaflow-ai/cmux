import Foundation

/// What this Mac's Chief home copied into which Hosted Chief, and for which
/// account (app-local; the copy steps are idempotent, so a lost record only
/// repeats skips).
@MainActor
struct HostedChiefLedger {
    enum Step: String { case history, memory, memoryStarted, brain }

    let session: String
    var defaults: UserDefaults = .standard

    /// The account this Chief home was copied for (another account does not copy it).
    var account: String? { defaults.string(forKey: "home.chief.hostedAccount.\(session)") }

    func claim(account: String) {
        if self.account == nil { defaults.set(account, forKey: "home.chief.hostedAccount.\(session)") }
    }

    func done(_ step: Step, chief: String) -> Bool { defaults.bool(forKey: key(step, chief)) }

    func mark(_ step: Step, chief: String) { defaults.set(true, forKey: key(step, chief)) }

    /// Copy runs that failed in a row; after ``maxFailures`` the copy gives up (logged).
    static let maxFailures = 3
    func failed(chief: String) -> Int { defaults.integer(forKey: "home.chief.hosted.\(session).\(chief).failures") }
    func recordFailure(chief: String) { defaults.set(failed(chief: chief) + 1, forKey: "home.chief.hosted.\(session).\(chief).failures") }
    func clearFailures(chief: String) { defaults.removeObject(forKey: "home.chief.hosted.\(session).\(chief).failures") }

    /// The server refused the content (counts toward giving up); a network, rate or server error does not.
    static func isRefusal(_ error: any Error) -> Bool {
        guard case let HostedChiefError.owner(code, _) = error else { return false }
        return !(code.contains("rate") || code.hasPrefix("http_5") || code.hasPrefix("internal") || code.contains("unavailable") || code == "brain_busy")
    }

    private func key(_ step: Step, _ chief: String) -> String { "home.chief.hosted.\(session).\(chief).\(step.rawValue)" }

    /// The import source's host: this Mac's Chief home session, as a token (ASCII 0x21-0x7e, at most 128).
    static func host(session: String) -> String {
        let token = String(String.UnicodeScalarView(session.unicodeScalars.filter { $0.value >= 0x21 && $0.value <= 0x7e }))
        return String(("mac-" + token).prefix(128))
    }
}
