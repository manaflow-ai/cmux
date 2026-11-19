import AppKit
public import CmuxNextSettings

/// The short sound a chat plays when something finishes (`pane.finishSound {kind}`): the page
/// decides when and asks only when the person turned the sound on (or, as `pane.lookSound`, when the
/// active look's sound pack may sound for it: ``lookSound``), so the host reads no other cmux
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
    /// Each sound by name or path, loaded once: a copy of the shared named sound, so its volume stays ours.
    private var sounds: [String: NSSound] = [:]

    /// A system or library sound by name, or a sound file by absolute path (a look's `file:` sound).
    private static func load(_ name: String) -> NSSound? {
        if name.hasPrefix("/") { return NSSound(contentsOfFile: name, byReference: true) }
        return NSSound(named: name)?.copy() as? NSSound
    }

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

    /// The active look's sound for `kind`: its theme file's sound pack while
    /// `notifications.sounds.lookPack` is on and no mute applies (``NotificationPreferences/lookSound(for:minuteOfDay:)``).
    /// The app sets it (AgentPanePageSettings); nil, or a nil answer, keeps the built-in sound.
    public static var lookSound: ((Kind) -> NotificationSoundChoice?)?

    /// The pack's moment for `kind`: a turn's end is `finished`, green checks `ciGreen`; a merge has none.
    nonisolated static func lookEvent(_ kind: Kind) -> NotificationSoundPreferences.LookEvent? {
        switch kind {
        case .turn: .finished
        case .ci: .ciGreen
        case .merged: nil
        }
    }

    /// The sound `kind` plays: the look's at its notification volume when it has one, else the built-in one at ``volume``;
    /// with `lookOnly` (`pane.lookSound`: the finish sound is off) nothing but the look's.
    static func pick(_ kind: Kind, look: NotificationSoundChoice?, lookOnly: Bool) -> (name: String, volume: Float)? {
        if let look { return (look.name, Float(min(max(look.volume, 0), 1))) }
        return lookOnly ? nil : (kind.soundName, Self.volume)
    }

    /// Plays `kind`'s sound, unless the system switch is off or another sound started under
    /// ``minimumGap`` ago. Returns at once: `NSSound.play()` plays in the background, and the sound
    /// stops on its own at its end (a sound under a second; nothing loops). With `lookOnly`, only the
    /// active look's sound pack plays (``lookSound``), and nothing when it has none.
    func play(_ kind: Kind, lookOnly: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        // A merge right after a turn's end still sounds: a bigger moment outranks the gap.
        let outranks = lastKind.map { kind.rank > $0.rank } ?? true
        guard outranks || Self.admits(now: now, last: lastPlayed), Self.systemAllowsUISounds else { return }
        guard let picked = Self.pick(kind, look: Self.lookSound?(kind), lookOnly: lookOnly),
              let sound = sounds[picked.name] ?? Self.load(picked.name) else { return }
        sounds[picked.name] = sound
        sound.volume = picked.volume
        lastPlayed = now
        lastKind = kind
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
