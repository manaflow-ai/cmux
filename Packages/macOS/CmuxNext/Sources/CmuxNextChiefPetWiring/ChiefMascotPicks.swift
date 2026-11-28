public import CmuxNextSettings
public import Foundation
import Observation

/// Each Chief's own pet character (Leo 2026-10-21: "the chief avatar switching the pet thing it needs
/// to apply per chief"). The default Chief's character is `home.chiefPetMascot`, the one the Chief pet
/// and Settings > Chief > Chief Pet show, so a pick made before Chiefs had their own stays the default
/// Chief's. Every other Chief keeps its pick here, by participant id, in the app's defaults; one that
/// never picked wears the default character (orb).
///
/// ```swift
/// let picks = ChiefMascotPicks(defaults: .standard, defaultChief: HomeChiefAvatars.defaultChief)
/// picks.remember("moon", for: "agent_scout01")
/// picks.mascot(of: "agent_scout01", in: settings.snapshot)  // "moon"
/// ```
///
/// The rules are `welcome.mascotPicksLoad`, `welcome.mascot`, `welcome.mascotPicked` and
/// `welcome.mascotRemember` (cmux-home-rules); this type keeps the picks and writes the defaults.
@Observable @MainActor
public final class ChiefMascotPicks {
    static let key = "home.chief.mascots"
    /// The default Chief's participant id: its character is `home.chiefPetMascot`.
    @ObservationIgnored public let defaultChief: String
    // UserDefaults is Apple-documented thread-safe; this type reads and writes it on the main actor only.
    @ObservationIgnored private let defaults: UserDefaults?
    /// Each other Chief's pick, by participant id.
    private(set) var picks: [String: String]

    /// - Parameters:
    ///   - defaults: where the picks are kept across launches; nil keeps them in memory.
    ///   - defaultChief: the default Chief's participant id (`HomeChiefAvatars.defaultChief`).
    public init(defaults: UserDefaults?, defaultChief: String) {
        self.defaults = defaults
        self.defaultChief = defaultChief
        // One entry that is not a character id is dropped, never the others.
        let stored = (defaults?.dictionary(forKey: Self.key) ?? [:]).compactMapValues { $0 as? String }
        let reply: PicksReply = welcomeRule("welcome.mascotPicksLoad", LoadInput(stored: stored, mascots: .setting), fallback: PicksReply(picks: [:]))
        picks = reply.picks
    }

    /// Whether `chief` (a participant id; nil: the default Chief) wears `home.chiefPetMascot`.
    public func isDefault(_ chief: String?) -> Bool { chief == nil || chief == defaultChief }

    /// The character Chief `chief` wears: the default Chief's is `snapshot`'s `home.chiefPetMascot`,
    /// another's its own pick, else the default character.
    public func mascot(of chief: String?, in snapshot: CmuxConfigSnapshot?) -> String {
        let input = PicksInput(chief: chief, defaultChief: defaultChief, picks: picks, snapshotMascot: snapshot?.homeChiefPetMascot)
        let reply: MascotReply = welcomeRule("welcome.mascot", input, fallback: MascotReply(mascot: HomeChiefPetSetting.mascotDefault))
        return reply.mascot
    }

    /// The character Chief `chief` (nil: the default Chief) was given by a pick (the popover, Settings >
    /// Chiefs, the config file), or nil while it wears the default without one: the default Chief's is
    /// `home.chiefPetMascot` when `file` (the config file's root) sets it, another's its own pick.
    public func picked(_ chief: String?, in file: JSONValue?) -> String? {
        // Only the default Chief reads the file, and only `home.chiefPetMascot`: the root whole is
        // ~157 KB for some people and the sidebar asks this per Chief per row, which JSON-encoded it
        // each time and blocked the main thread 2-6 s with ~1,100 workspaces (as `JSONValue.keeping`).
        let read = isDefault(chief) ? file?.keeping([Array(HomeChiefPetSetting.mascotPath)]) : nil
        let input = PicksInput(chief: chief, defaultChief: defaultChief, picks: picks, file: read)
        let reply: PickedReply = welcomeRule("welcome.mascotPicked", input, fallback: PickedReply(picked: nil))
        return reply.picked
    }

    /// Makes `mascot` the character of Chief `chief`, which is not the default Chief (its character is
    /// the setting, written through the settings). An id that is not a character is ignored.
    public func remember(_ mascot: String, for chief: String) {
        let input = PicksInput(chief: chief, defaultChief: defaultChief, picks: picks, mascot: mascot)
        let reply: RememberReply = welcomeRule("welcome.mascotRemember", input, fallback: RememberReply(picks: picks, write: nil))
        guard let write = reply.write else { return }
        picks = reply.picks
        defaults?.set(write.value, forKey: write.key)
    }
}

// The mascot ops' wire shapes (cmux-home-rules `welcome/pet.rs`).
private nonisolated struct Mascots: Encodable {
    /// The generated `home.chiefPetMascot` choices, default and path.
    static var setting: Mascots {
        Mascots(values: Array(HomeChiefPetSetting.mascotValues), default: HomeChiefPetSetting.mascotDefault, path: Array(HomeChiefPetSetting.mascotPath))
    }

    var values: [String]
    var `default`: String
    var path: [String]
}

private nonisolated struct LoadInput: Encodable {
    var stored: [String: String]
    var mascots: Mascots
}

private nonisolated struct PicksInput: Encodable {
    var chief: String?
    var defaultChief: String
    var picks: [String: String]
    var mascots = Mascots.setting
    var snapshotMascot: String?
    var file: JSONValue?
    var mascot: String?
}

private nonisolated struct PicksReply: Decodable {
    var picks: [String: String]
}

private nonisolated struct MascotReply: Decodable {
    var mascot: String
}

private nonisolated struct PickedReply: Decodable {
    var picked: String?
}

private nonisolated struct RememberReply: Decodable {
    var picks: [String: String]
    var write: Write?

    nonisolated struct Write: Decodable {
        var key: String
        var value: [String: String]
    }
}
