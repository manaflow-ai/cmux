import AppKit

/// ``NotificationSoundPlaying`` with `NSSound`: one instance per sound, kept, so a burst never
/// loads a file twice and a sound still playing restarts instead of stacking.
@MainActor
public final class NotificationSoundPlayer: NotificationSoundPlaying {
    private var sounds: [String: NSSound] = [:]

    /// A player with no sound loaded yet.
    public init() {}

    public func play(_ name: String, volume: Double, banner: Bool) {
        guard name != "none", !name.isEmpty else { return }
        guard name != "default" else {
            if !banner { NSSound.beep() }
            return
        }
        guard let sound = sound(named: name) else { return }
        sound.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
    }

    private func sound(named name: String) -> NSSound? {
        if let sound = sounds[name] { return sound }
        let path = (name as NSString).expandingTildeInPath
        // A path loads by reference (NSSound reads the file when it plays); a name is the system's
        // cached lookup, copied so this instance's volume never changes another player's.
        let sound = path.hasPrefix("/") ? NSSound(contentsOfFile: path, byReference: true) : NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        if let sound { sounds[name] = sound }
        return sound
    }
}
