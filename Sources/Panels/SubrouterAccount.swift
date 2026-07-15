import Foundation

/// One account reported by the bundled Subrouter executable.
struct SubrouterAccount: Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let authMode: String

    init(id: String, provider: String, authMode: String) {
        self.id = id
        self.provider = provider
        self.authMode = authMode
    }
}
