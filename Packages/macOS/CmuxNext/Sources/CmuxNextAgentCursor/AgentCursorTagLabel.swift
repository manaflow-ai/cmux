import Foundation

/// The agent cursor's tag text when its origin is known: who drives and where
/// ("a201 · cursor-gallery", "Chief · Home"; user, 2026-10-20). The place is
/// cut with "…" to keep the tag at most ``maxLength`` characters; the driver
/// is cut only past ``maxDriverLength``.
nonisolated public struct AgentCursorTagLabel: Sendable, Equatable {
    /// The longest tag text, in characters.
    public static let maxLength = 36
    /// The longest driver name, in characters.
    public static let maxDriverLength = 14
    /// Between the driver and the place.
    public static let separator = " · "

    /// The tag text.
    public let text: String

    /// - Parameters:
    ///   - driver: Who drives: the Chief, or the agent's name.
    ///   - place: The workspace the driver works in; nil or blank shows the driver alone.
    public init(driver: String, place: String?) {
        let driver = Self.cut(driver.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.maxDriverLength)
        let place = (place ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !place.isEmpty else {
            text = driver
            return
        }
        let room = Self.maxLength - driver.count - Self.separator.count
        text = room < 2 ? driver : driver + Self.separator + Self.cut(place, to: room)
    }

    private static func cut(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length - 1)) + "…" : text
    }
}
