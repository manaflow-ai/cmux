public import Foundation

/// The cached, non-secret harness facts reported by one machine's acpmux owner.
///
/// An empty snapshot means the owner has no cached observations. It does
/// not establish that this machine has no agent CLIs installed.
public nonisolated struct AcpmuxHarnessInventory: Decodable, Sendable, Equatable {
    /// The configured harness/profile observations, without paths or commands.
    public let harnesses: [Harness]

    /// One cached observation. A profile id identifies a configured harness;
    /// it is not an account identity or necessarily a provider family.
    public nonisolated struct Harness: Decodable, Sendable, Equatable {
        /// The owner's configured profile id.
        public let id: String
        /// The CLI family identified from the same check's executable or package.
        /// Nil for old owners or unclassified evidence; unrecognized future
        /// strings decode as unknown. Never substitute the profile id.
        public let family: AgentCLIFamily?
        /// The installation channel the owner detected.
        public let channel: Channel
        /// The installed version, or nil when the owner could not establish it.
        public let version: String?
        /// The latest cached release for this installation channel.
        public let latest: String?
        /// When the latest release was observed, in milliseconds since the epoch.
        public let latestCheckedAt: UInt64?
        /// Whether the owner found an available newer release.
        public let outdated: Bool
        /// Presence-only sign-in evidence; never account labels or credentials.
        public let auth: Auth
        /// When this observation was checked, in milliseconds since the epoch.
        public let checkedAt: UInt64
    }

    /// The observed install channel. A launcher does not prove that the
    /// agent behind it is installed, and standalone does not imply native updates.
    public nonisolated enum Channel: String, Decodable, Sendable, Equatable {
        /// A global npm installation.
        case npm
        /// A global Bun installation.
        case bun
        /// A Homebrew formula.
        case brew
        /// A Homebrew cask.
        case brewCask
        /// A recognized vendor installation.
        case native
        /// An interpreter or launcher whose underlying agent was not checked.
        case launcher
        /// A binary whose installation method is unknown.
        case standalone
        /// The configured executable was not found.
        case missing
    }

    /// Sign-in evidence established by the owner's existing health checker.
    public nonisolated enum Auth: String, Decodable, Sendable, Equatable {
        /// A successful check established a usable sign-in.
        case signedIn
        /// The owner has evidence that the harness is signed out.
        case signedOut
        /// No decisive sign-in evidence is available.
        case unknown
    }

    private enum CodingKeys: String, CodingKey { case view, cached, harnesses }

    /// Decodes only an explicitly identified cache-only inventory response.
    /// - Parameter decoder: A decoder for the owner's result object.
    /// - Throws: A decoding error for a legacy health response or invalid fields.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard try fields.decode(String.self, forKey: .view) == "inventory",
              try fields.decode(Bool.self, forKey: .cached) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected a cached harness inventory"))
        }
        harnesses = try fields.decode([Harness].self, forKey: .harnesses)
    }
}
