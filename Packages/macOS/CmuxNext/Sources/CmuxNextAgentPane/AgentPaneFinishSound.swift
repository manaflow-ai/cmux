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

    /// Where a page's finish moments find the active look's sound (``AgentPaneShared/lookSound``), given where the
    /// chat sits (``Placement``).
    public typealias LookSource = @MainActor (Kind, Placement) -> NotificationSoundPreferences.LookMoment

    /// Where the chat that finished sits, for the mutes a look's sound obeys like any notification sound.
    public nonisolated struct Placement: Hashable, Sendable {
        /// Its workspace's key on this Mac's daemon (``AgentPaneTransport/workspaceID``, the id
        /// `notifications.mutedWorkspaces` lists); nil for none or another machine's workspace.
        public var workspace: String?
        /// The person is looking at it: its window is key in the active app and the pane is shown.
        public var viewed: Bool

        public init(workspace: String? = nil, viewed: Bool = false) {
            self.workspace = workspace
            self.viewed = viewed
        }
    }

    /// The active look's sound for `kind`: its theme file's sound pack while
    /// `notifications.sounds.lookPack` is on (``NotificationPreferences/lookSound(for:minuteOfDay:)``), muted under
    /// quiet hours, a muted workspace, `sounds.when` (``muted(_:when:workspaceMuted:viewed:appActive:)``) and the other
    /// notification mutes. The pane's view sets it from the app's ``AgentPaneShared``; nil, or an unset answer,
    /// keeps the built-in sound.
    var lookSound: LookSource?
    /// Where the chat sits now (``Placement``); the pane's view sets it.
    var placement: (@MainActor () -> Placement)?

    /// The app's look source: `settings`' notification preferences at the local time of each sound.
    public static func lookSource(_ settings: @escaping @MainActor () -> SettingsController?) -> LookSource {
        { kind, placement in
            guard let settings = settings(), let event = lookEvent(kind) else { return .unset }
            let notifications = settings.snapshot.notifications
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let moment = notifications.lookSound(for: event, minuteOfDay: (now.hour ?? 0) * 60 + (now.minute ?? 0))
            let workspaceMuted = placement.workspace.map(notifications.mutedWorkspaces.contains) ?? false
            return muted(moment, when: notifications.sounds.when, workspaceMuted: workspaceMuted, viewed: placement.viewed,
                         appActive: NSApp?.isActive ?? false)
        }
    }

    /// The pack's moment for `kind`: a turn's end is `finished`, green checks `ciGreen`; a merge has none.
    nonisolated static func lookEvent(_ kind: Kind) -> NotificationSoundPreferences.LookEvent? {
        switch kind {
        case .turn: .finished
        case .ci: .ciGreen
        case .merged: nil
        }
    }

    /// `moment` under the chat's mutes, as a notification's sound obeys them (NotificationPolicy): nothing in a
    /// muted workspace, and `notifications.sounds.when` (`unlessViewed`: not while the person looks at this chat,
    /// `whenInactive`: not while cmux is active). An unset moment stays unset: the built-in finish sound is the
    /// page's own setting.
    nonisolated static func muted(_ moment: NotificationSoundPreferences.LookMoment, when: NotificationSoundTiming,
                                  workspaceMuted: Bool, viewed: Bool, appActive: Bool) -> NotificationSoundPreferences.LookMoment {
        guard moment != .unset else { return moment }
        guard !workspaceMuted, when.plays(viewed: viewed, appActive: appActive) else { return .muted }
        return moment
    }

    /// The sound `kind` plays: the look's at its notification volume when it has one, nothing when the pack
    /// mutes the moment (its `"none"`, quiet hours, volume 0), else the built-in one at ``volume``;
    /// with `lookOnly` (`pane.lookSound`: the finish sound is off) nothing but the look's.
    static func pick(_ kind: Kind, look: NotificationSoundPreferences.LookMoment, lookOnly: Bool) -> (name: String, volume: Float)? {
        switch look {
        case .play(let choice): return (choice.name, Float(min(max(choice.volume, 0), 1)))
        case .muted: return nil
        case .unset: return lookOnly ? nil : (kind.soundName, Self.volume)
        }
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
        guard let picked = Self.pick(kind, look: lookSound?(kind, placement?() ?? Placement()) ?? .unset, lookOnly: lookOnly),
              let sound = sounds[picked.name] ?? Self.load(picked.name) else { return }
        sounds[picked.name] = sound
        sound.volume = picked.volume
        lastPlayed = now
        lastKind = kind
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
