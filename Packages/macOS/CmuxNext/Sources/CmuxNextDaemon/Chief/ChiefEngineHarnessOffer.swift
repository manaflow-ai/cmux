public import Foundation

/// One engine `chief.engine.get` offers the Chief picker (`offered.harnesses`,
/// optchat-chief brain/harness_offer.rs): an acpmux harness a Chief turn can
/// run on, with what it supports and, when it cannot run, why. A
/// `chief.engine.set {harness: id}` switches the Chief to it from the next turn.
public struct ChiefEngineHarness: Decodable, Sendable, Equatable, Identifiable {
    /// What the engine takes, as the brain checks a set.
    public struct Capabilities: Decodable, Sendable, Equatable {
        /// The efforts it takes: the profile's own list, else every one the brain accepts.
        public var efforts: [String]
        /// The speeds its turns run (`fast` only on a codex-family harness).
        public var speeds: [String]
        /// Whether its sessions resume after a restart; nil when the profile does not say.
        public var resume: Bool?
        /// Whether it has permission modes; nil when the profile does not say.
        public var permissionModes: Bool?
        /// The profile's own fast flag; nil when it does not say.
        public var fast: Bool?

        public init(efforts: [String] = [], speeds: [String] = [], resume: Bool? = nil,
                    permissionModes: Bool? = nil, fast: Bool? = nil) {
            self.efforts = efforts
            self.speeds = speeds
            self.resume = resume
            self.permissionModes = permissionModes
            self.fast = fast
        }

        enum CodingKeys: String, CodingKey { case efforts, speeds, resume, permissionModes, fast }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
            speeds = try c.decodeIfPresent([String].self, forKey: .speeds) ?? []
            resume = try? c.decodeIfPresent(Bool.self, forKey: .resume)
            permissionModes = try? c.decodeIfPresent(Bool.self, forKey: .permissionModes)
            fast = try? c.decodeIfPresent(Bool.self, forKey: .fast)
        }
    }

    /// The acpmux harness id (`claude-sr`, `codex`, `opencode`, `unii`): `chief.engine.set`'s `harness`.
    public var id: String
    /// The profile's or the catalog's name; two profiles of one name carry their ids.
    public var displayName: String
    /// acpmux's family (`claude`, `codex`, `opencode`, `unii`, ...).
    public var family: String
    /// The layout the Chief gives it: `claude`, `codex` or `other`.
    public var chiefFamily: String
    /// acpmux's kind (`claude-stdio`, `acp`).
    public var kind: String
    public var capabilities: Capabilities
    /// Whether a turn on it would be refused (its launcher is missing, the harness gate refuses it).
    public var unavailable: Bool
    /// Why it cannot run, as the brain says it; nil when it can (or the brain gave no reason).
    public var unavailableReason: String?
    public var description: String?
    /// A built-in icon name, or an absolute path to the icon file.
    public var icon: String?
    /// The command that signs in to it (`unii login`).
    public var login: String?

    /// Whether a turn can run on it now.
    public var isAvailable: Bool { !unavailable }

    enum CodingKeys: String, CodingKey {
        case id, displayName, family, chiefFamily, kind, capabilities, unavailable, unavailableReason
        case description, icon, login
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        chiefFamily = try c.decodeIfPresent(String.self, forKey: .chiefFamily) ?? "other"
        family = try c.decodeIfPresent(String.self, forKey: .family) ?? chiefFamily
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "acp"
        capabilities = try c.decodeIfPresent(Capabilities.self, forKey: .capabilities) ?? Capabilities()
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? (unavailableReason != nil)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        login = try c.decodeIfPresent(String.self, forKey: .login)
    }
}

/// `offered.harnesses` of a `chief.engine.get` (or `chief.engine.set`) answer,
/// decoded from the whole answer (empty from a brain that offers none). A row
/// this app cannot read is skipped, not the whole list.
public struct ChiefEngineHarnessOffer: Decodable, Sendable, Equatable {
    public var harnesses: [ChiefEngineHarness]

    public init(harnesses: [ChiefEngineHarness] = []) {
        self.harnesses = harnesses
    }

    enum CodingKeys: String, CodingKey { case offered, harnesses }

    public init(from decoder: any Decoder) throws {
        let answer = try decoder.container(keyedBy: CodingKeys.self)
        harnesses = []
        guard answer.contains(.offered),
              let offered = try? answer.nestedContainer(keyedBy: CodingKeys.self, forKey: .offered),
              offered.contains(.harnesses),
              var rows = try? offered.nestedUnkeyedContainer(forKey: .harnesses) else { return }
        while !rows.isAtEnd {
            if let row = try? rows.decode(ChiefEngineHarness.self) {
                harnesses.append(row)
            } else {
                // Step past the row this app cannot read.
                _ = try rows.decode(JSONValue.self)
            }
        }
    }

    /// The engine whose harness id is `id`.
    public func harness(id: String) -> ChiefEngineHarness? {
        harnesses.first { $0.id == id }
    }

    /// The picker's order: the engines that can run a turn, then the rest, each in the brain's order.
    public var pickerOrder: [ChiefEngineHarness] {
        harnesses.filter(\.isAvailable) + harnesses.filter { !$0.isAvailable }
    }
}
