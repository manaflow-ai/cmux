import CmuxChief
import Foundation

/// Chief's look: the header and list avatar text (at most two characters;
/// an emoji counts as one), kept in `<Chief home>/state/profile.json` beside
/// the conversations (cmux-next keeps it in `profile.json` too). Empty
/// shows the conversation's initials.
struct ChiefProfile: Codable, Equatable {
    var avatar: String?

    /// Posted after the avatar is saved (the list and other headers re-read it).
    static let didChange = Notification.Name("ChiefProfile.didChange")

    static func url(in home: ChiefHome) -> URL {
        home.stateDirectory.appendingPathComponent("profile.json", isDirectory: false)
    }

    static func load(from home: ChiefHome) -> ChiefProfile {
        guard let data = try? Data(contentsOf: url(in: home)),
              let profile = try? JSONDecoder().decode(ChiefProfile.self, from: data) else { return ChiefProfile() }
        return profile
    }

    func save(to home: ChiefHome) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: home), options: .atomic)
    }

    /// `text` trimmed to the avatar's two characters; nil when empty.
    static func avatarText(_ text: String) -> String? {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `text` is letters and digits (a monogram) rather than an emoji.
    static func isMonogram(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
