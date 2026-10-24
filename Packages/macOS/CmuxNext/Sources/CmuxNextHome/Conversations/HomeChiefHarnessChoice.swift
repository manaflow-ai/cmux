public import Foundation

/// One engine New Chief offers (Lawrence 2026-10-23: "show all possible harnesses by default"):
/// every official engine and every harness this Mac's acpmux lists, with whether it can run here.
/// A harness that cannot is still offered, marked, so the person sees all of them.
public nonisolated struct HomeChiefHarnessChoice: Hashable, Sendable, Identifiable {
    /// Whether the harness can run on this Mac now.
    public enum State: String, Hashable, Sendable {
        /// Installed and not known to be signed out.
        case ready
        /// acpmux does not have it on this Mac.
        case notInstalled
        /// Installed, but its health check found it signed out.
        case signedOut
        /// acpmux has it, but its launcher check failed.
        case unavailable
    }

    /// The acpmux harness id the Chief's engine is set to.
    public let id: String
    /// The name the sheet shows (an official engine's title, else acpmux's name).
    public let title: String
    /// Whether it can run here.
    public let state: State

    /// The engine a Chief made on this choice runs on.
    public var backend: ChiefBackend { ChiefBackend.harness(id) }

    /// The popup's item title: the name, and what it needs when it is not ready.
    public var itemTitle: String {
        guard let note = stateNote else { return title }
        return "\(title) — \(note)"
    }

    /// What a choice that is not ready needs, in a few words; nil when it is ready.
    public var stateNote: String? {
        switch state {
        case .ready: nil
        case .notInstalled: String(localized: "home.chief.harness.notInstalled", defaultValue: "Not installed", bundle: .module)
        case .signedOut: String(localized: "home.chief.harness.signedOut", defaultValue: "Signed out", bundle: .module)
        case .unavailable: String(localized: "home.chief.harness.unavailable", defaultValue: "Unavailable", bundle: .module)
        }
    }

    /// The hint under the popup for a choice that is not ready; nil when it is ready.
    public var stateHint: String? {
        switch state {
        case .ready: nil
        case .notInstalled:
            String(localized: "home.chief.harness.notInstalledHint",
                   defaultValue: "This harness is not installed on this Mac. Install it from Settings > Agents; the Chief answers once it is.",
                   bundle: .module)
        case .signedOut:
            String(localized: "home.chief.harness.signedOutHint",
                   defaultValue: "This harness is signed out. Sign in from Settings > Agents, or add an API key; the Chief answers once it can.",
                   bundle: .module)
        case .unavailable:
            String(localized: "home.chief.harness.unavailableHint",
                   defaultValue: "This harness cannot start on this Mac now. Settings > Agents shows why.", bundle: .module)
        }
    }

    /// - Parameters:
    ///   - id: the acpmux harness id.
    ///   - title: the name to show.
    ///   - state: whether it can run here.
    public init(id: String, title: String, state: State) {
        self.id = id
        self.title = title
        self.state = state
    }

    /// The choices for `listed`: the official engines first (``ChiefBackend/official``, each marked
    /// not installed when acpmux does not list it; UniiChat is acpmux's built-in, so never), then
    /// every other listed harness in acpmux's order, once each.
    ///
    /// ```swift
    /// let choices = HomeChiefHarnessChoice.choices(listed: [HomeChiefListedHarness(id: "opencode", name: "OpenCode")])
    /// // claude, codex, muse (not installed), unii, opencode
    /// ```
    public static func choices(listed: [HomeChiefListedHarness]) -> [HomeChiefHarnessChoice] {
        var byID: [String: HomeChiefListedHarness] = [:]
        for harness in listed where byID[harness.id] == nil { byID[harness.id] = harness }
        let state = { (harness: HomeChiefListedHarness) -> State in
            if harness.unavailable != nil { return .unavailable }
            return harness.signedOut ? .signedOut : .ready
        }
        var out = ChiefBackend.official.map { backend -> HomeChiefHarnessChoice in
            if let harness = byID[backend.id] { return HomeChiefHarnessChoice(id: backend.id, title: backend.title, state: state(harness)) }
            // An empty list is acpmux not answering: nothing is known missing.
            let missing = !listed.isEmpty && backend != .unii
            return HomeChiefHarnessChoice(id: backend.id, title: backend.title, state: missing ? .notInstalled : .ready)
        }
        var seen = Set(out.map(\.id))
        for harness in listed where !harness.id.isEmpty && seen.insert(harness.id).inserted {
            out.append(HomeChiefHarnessChoice(id: harness.id, title: harness.name.isEmpty ? harness.id : harness.name, state: state(harness)))
        }
        return out
    }
}
