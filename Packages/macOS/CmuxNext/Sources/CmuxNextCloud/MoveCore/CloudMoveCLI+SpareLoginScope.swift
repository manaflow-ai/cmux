public import Foundation

public extension CloudMoveCLI {
    /// Facts Rust binds to a warm-login receipt. No credential bytes cross this boundary.
    struct SpareLoginScope: Sendable, Equatable {
        public var platform: String
        public var team: String
        public var install: String
        public var credential: String

        public init(platform: URL, team: String, install: String, credential: String) {
            self.platform = platform.absoluteString
            self.team = team
            self.install = install
            self.credential = credential
        }

        var object: [String: String] {
            ["platform": platform, "team": team, "install": install, "credential": credential]
        }
    }
}
