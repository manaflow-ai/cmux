#if DEBUG
import Observation

/// DEBUG ONLY (Environment Secrets Playground): which direction and which state the window shows, and
/// the live choices the person makes inside a direction (a review row's type, the open row).
@MainActor @Observable
final class EnvSecretsPlaygroundModel {
    /// One design direction behind the picker.
    enum Direction: Int, CaseIterable, Identifiable {
        case ledger = 1, sentences, inspector

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .ledger: "Ledger"
            case .sentences: "Sentences"
            case .inspector: "Inspector"
            }
        }

        /// The axis the direction takes, in a phrase.
        var axis: String {
            switch self {
            case .ledger: "Dense table, details open in place"
            case .sentences: "One card per value, each says in words where it goes"
            case .inspector: "List and detail side by side, like a Mac settings pane"
            }
        }
    }

    /// One state every direction draws.
    enum Scene: Int, CaseIterable, Identifiable {
        case empty, paste, saved, noHost, approval, audit, revoke, scopes, request, cli

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .empty: "Empty"
            case .paste: "Paste .env"
            case .saved: "Saved secret"
            case .noHost: "No host"
            case .approval: "Host approval"
            case .audit: "History"
            case .revoke: "Revoke now"
            case .scopes: "Scopes"
            case .request: "Agent asks"
            case .cli: "Terminal"
            }
        }
    }

    var direction: Direction = .ledger
    var scene: Scene = .empty
    /// Nil follows the app's appearance.
    var dark: Bool?
    /// The type the person picked for each review row, by name.
    var reviewKinds: [String: EnvSecretsKind] = [:]
    /// The scope tab the page shows.
    var scope: EnvSecretsEntry.Scope = .team
    /// Where the agent's requested secret is kept; Chat by default.
    var requestScope: EnvSecretsEntry.Scope = .chat
    let sample = EnvSecretsSample()

    /// The request card's "where to keep it" choices, the same in every direction.
    var requestScopeChoices: [EnvRequestScopeChoice] { EnvRequestScopeChoice.all }

    /// The request card's save button for ``requestScope``.
    var requestSaveTitle: String {
        switch requestScope {
        case .chat: "Save for this chat"
        case .personal: "Save for me"
        case .team: "Ask an admin to approve"
        }
    }

    func kind(of entry: EnvSecretsEntry) -> EnvSecretsKind { reviewKinds[entry.name] ?? entry.kind }

    func setKind(_ kind: EnvSecretsKind, for entry: EnvSecretsEntry) { reviewKinds[entry.name] = kind }

    /// The review rows with the person's picks applied.
    var review: [EnvSecretsEntry] {
        sample.review.map { entry in
            var entry = entry
            entry.kind = kind(of: entry)
            return entry
        }
    }
}
#endif
