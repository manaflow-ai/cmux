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
        picks = (defaults?.dictionary(forKey: Self.key) ?? [:]).compactMapValues { $0 as? String }
            .filter { HomeChiefPetSetting.mascots.contains($0.value) }
    }

    /// Whether `chief` (a participant id; nil: the default Chief) wears `home.chiefPetMascot`.
    public func isDefault(_ chief: String?) -> Bool { chief == nil || chief == defaultChief }

    /// The character Chief `chief` wears: the default Chief's is `snapshot`'s `home.chiefPetMascot`,
    /// another's its own pick, else the default character.
    public func mascot(of chief: String?, in snapshot: CmuxConfigSnapshot?) -> String {
        guard let chief, !isDefault(chief) else { return snapshot?.homeChiefPetMascot ?? HomeChiefPetSetting.defaultMascot }
        return picks[chief] ?? HomeChiefPetSetting.defaultMascot
    }

    /// The character Chief `chief` (nil: the default Chief) was given by a pick (the popover, Settings >
    /// Chiefs, the config file), or nil while it wears the default without one: the default Chief's is
    /// `home.chiefPetMascot` when `file` (the config file's root) sets it, another's its own pick.
    public func picked(_ chief: String?, in file: JSONValue?) -> String? {
        guard let chief, !isDefault(chief) else {
            return file?.value(at: HomeChiefPetSetting.mascotPath)?.stringValue.flatMap { HomeChiefPetSetting.mascots.contains($0) ? $0 : nil }
        }
        return picks[chief]
    }

    /// Makes `mascot` the character of Chief `chief`, which is not the default Chief (its character is
    /// the setting, written through the settings). An id that is not a character is ignored.
    public func remember(_ mascot: String, for chief: String) {
        guard !isDefault(chief), HomeChiefPetSetting.mascots.contains(mascot), picks[chief] != mascot else { return }
        picks[chief] = mascot
        defaults?.set(picks, forKey: Self.key)
    }
}
