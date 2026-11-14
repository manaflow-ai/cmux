/// The space verbs' rules (cmux-window-rules `workspaces`): `space.setDefaults` arguments and the
/// questions of Delete Space and Clear Space Terminal Defaults.
extension WindowRules {
    /// A change to a space's directory.
    public nonisolated enum CwdChange: Decodable, Equatable, Sendable {
        case clear, set(String)

        private enum CodingKeys: String, CodingKey { case kind, path }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .kind) == "clear" {
                self = .clear
            } else {
                self = .set(try container.decode(String.self, forKey: .path))
            }
        }
    }

    /// The fields a `space.setDefaults` run names; nil leaves a field as the space has it.
    public nonisolated struct DefaultsPatch: Decodable, Equatable, Sendable {
        public var cwd: CwdChange?
        /// Empty clears the environment.
        public var env: [String: String]?

        public init(cwd: CwdChange?, env: [String: String]?) {
            self.cwd = cwd
            self.env = env
        }
    }

    /// Why a `space.setDefaults` run is refused.
    public nonisolated enum DefaultsRefusal: String, Decodable, Error, Sendable {
        case defaultsMustBeText, cwdMustBeAbsolute, envMustBeObject
    }

    /// The fields a run names: `cwd` and `env` nil when not named, `.some(nil)` when named with a
    /// value that is not text; `cwd` comes with `~` already expanded. Nil when the FFI does not answer.
    public func spaceDefaults(cwd: String??, env: String??) -> Result<DefaultsPatch, DefaultsRefusal>? {
        struct Argument: Encodable { var text: String? }
        struct Request: Encodable { var cwd: Argument?, env: Argument? }
        struct Reply: Decodable { var patch: DefaultsPatch?, refusal: DefaultsRefusal? }
        let request = Request(cwd: cwd.map { Argument(text: $0) }, env: env.map { Argument(text: $0) })
        guard let reply = call("window_workspace_space_defaults", request, as: Reply.self) else { return nil }
        if let patch = reply.patch { return .success(patch) }
        return reply.refusal.map { .failure($0) }
    }

    /// What a Delete Space run asks.
    public nonisolated enum SpaceDelete: Decodable, Equatable, Sendable {
        /// Runs without asking.
        case runs
        /// Read what the closing terminals run, then ask again with them.
        case readPrograms
        case prompt([String])

        private enum CodingKeys: String, CodingKey { case ask, programs }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .ask) {
            case "readPrograms": self = .readPrograms
            case "prompt": self = .prompt(try container.decode([String].self, forKey: .programs))
            default: self = .runs
            }
        }
    }

    /// Delete Space asks only while a closing terminal runs a program and `warn` is on; a move never asks.
    public func spaceDelete(warn: Bool, resolved: Bool, defaultSpace: Bool, moves: Bool, programs: [String]?) -> SpaceDelete {
        struct Request: Encodable { var warn: Bool, resolved: Bool, defaultSpace: Bool, moves: Bool, programs: [String]? }
        let request = Request(warn: warn, resolved: resolved, defaultSpace: defaultSpace, moves: moves, programs: programs)
        return call("window_workspace_space_delete", request, as: SpaceDelete.self) ?? .runs
    }

    /// What the daemon said of a space's held defaults.
    public nonisolated enum HeldDefaults: String, Encodable, Sendable {
        case notAsked, unanswered, held, empty
    }

    /// What a Clear Space Terminal Defaults run does.
    public nonisolated enum ClearDefaults: String, Decodable, Sendable {
        case ask, run, readDaemon
    }

    /// Clear asks while the space has defaults (`shown` in the mirror, a run `inFlight`, or `held`
    /// by the daemon); one with none runs. An FFI that does not answer asks.
    public func spaceClearDefaults(resolved: Bool, shown: Bool, inFlight: Bool, connected: Bool, held: HeldDefaults) -> ClearDefaults {
        struct Request: Encodable { var resolved: Bool, shown: Bool, inFlight: Bool, connected: Bool, held: HeldDefaults }
        struct Reply: Decodable { var clear: ClearDefaults }
        let request = Request(resolved: resolved, shown: shown, inFlight: inFlight, connected: connected, held: held)
        return call("window_workspace_space_clear_defaults", request, as: Reply.self)?.clear ?? .ask
    }
}
