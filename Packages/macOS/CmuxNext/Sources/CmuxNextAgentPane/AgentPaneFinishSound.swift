import AppKit

/// The short sound a chat plays when something finishes (`pane.finishSound {kind}`): the page
/// decides when and asks only when the person turned the sound on, so the host reads no cmux
/// setting. The host keeps the system's own switch (Sound settings, "Play user interface sound
/// effects") and plays at most one sound per ``minimumGap`` for its chat page, so a burst of
/// finishes makes one sound. ``AgentPaneModel`` owns one per page.
public final class AgentPaneFinishSound {
    /// What finished.
    public nonisolated enum Kind: String, Hashable, Sendable {
        /// An agent turn ended.
        case turn
        /// A CI run went green.
        case ci
        /// A pull request merged.
        case merged

        /// Which sound wins a burst: a merge, then green checks, then a turn's end (the page's ranks).
        var rank: Int {
            switch self {
            case .turn: 0
            case .ci: 1
            case .merged: 2
            }
        }

        /// The built-in system sound (`/System/Library/Sounds`).
        var soundName: NSSound.Name {
            switch self {
            case .turn: "Bottle"
            case .ci: "Pop"
            case .merged: "Glass"
            }
        }
    }

    /// The shortest time between two sounds, in seconds.
    static let minimumGap: TimeInterval = 1.5
    /// The volume the sounds play at (0...1), under the system volume.
    static let volume: Float = 0.5

    /// When the last sound started (`ProcessInfo.systemUptime`) and its kind; nil before the first.
    private var lastPlayed: TimeInterval?
    private var lastKind: Kind?
    /// Each kind's sound, loaded once: a copy of the shared named sound, so its volume stays ours.
    private var sounds: [Kind: NSSound] = [:]

    /// A player that has played nothing yet.
    public init() {}

    /// Whether the system's "Play user interface sound effects" switch is on. It lives in the
    /// `com.apple.systemsound` domain; some systems write it to the global domain, so an explicit
    /// off in either wins. Unset means on, the system default.
    static var systemAllowsUISounds: Bool {
        let key = "com.apple.sound.uiaudio.enabled"
        let domains = [UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: key),
                       UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key]]
        return !domains.contains { ($0 as? Bool) == false }
    }

    /// Whether a sound may start at `now`: at least ``minimumGap`` after the last one.
    static func admits(now: TimeInterval, last: TimeInterval?) -> Bool {
        guard let last else { return true }
        return now - last >= minimumGap
    }

    /// Plays `kind`'s sound, unless the system switch is off or another sound started under
    /// ``minimumGap`` ago. Returns at once: `NSSound.play()` plays in the background, and the sound
    /// stops on its own at its end (a sound under a second; nothing loops).
    func play(_ kind: Kind) {
        let now = ProcessInfo.processInfo.systemUptime
        // A merge right after a turn's end still sounds: a bigger moment outranks the gap.
        let outranks = lastKind.map { kind.rank > $0.rank } ?? true
        guard outranks || Self.admits(now: now, last: lastPlayed), Self.systemAllowsUISounds else { return }
        guard let sound = sounds[kind] ?? (NSSound(named: kind.soundName)?.copy() as? NSSound) else { return }
        sounds[kind] = sound
        sound.volume = Self.volume
        lastPlayed = now
        lastKind = kind
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
