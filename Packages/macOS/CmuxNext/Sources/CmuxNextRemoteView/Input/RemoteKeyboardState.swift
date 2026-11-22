public import AppKit

/// Which keys and buttons the host believes are down. Every down the pane
/// sends is recorded here, so losing focus (or the release chord) can send
/// the matching ups and no key stays stuck on the host. Pure: tested
/// without events.
public nonisolated struct RemoteKeyboardState: Sendable, Equatable {
    public private(set) var heldKeys: Set<UInt16> = []
    public private(set) var heldButtons: Set<RemoteMouseButton> = []

    public init() {}

    /// A key down. Auto-repeat is the host's job, so repeats send nothing.
    public mutating func keyDown(keyCode: UInt16, isRepeat: Bool) -> [RemoteInputEvent] {
        guard let usage = RemoteHIDKeyMap().usage(forKeyCode: keyCode) else { return [] }
        if isRepeat, heldKeys.contains(keyCode) { return [] }
        heldKeys.insert(keyCode)
        return [.key(usage: usage, down: true)]
    }

    public mutating func keyUp(keyCode: UInt16) -> [RemoteInputEvent] {
        guard heldKeys.remove(keyCode) != nil, let usage = RemoteHIDKeyMap().usage(forKeyCode: keyCode) else { return [] }
        return [.key(usage: usage, down: false)]
    }

    /// `flagsChanged` for modifier key `keyCode` with the new `flags`.
    /// Left and right keys are separate usages; the device-independent
    /// family flag resynchronizes a missed event (flag clear = every key of
    /// that family is up). Caps Lock sends a tap: HID toggles on the press.
    public mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [RemoteInputEvent] {
        guard let usage = RemoteHIDKeyMap().usage(forKeyCode: keyCode) else { return [] }
        if keyCode == Self.capsLock {
            return [.key(usage: usage, down: true), .key(usage: usage, down: false)]
        }
        guard let family = Self.family(of: keyCode) else { return [] }
        if !flags.contains(family) {
            let released = heldKeys.filter { Self.family(of: $0) == family }.sorted()
            return released.flatMap { keyUp(keyCode: $0) }
        }
        if heldKeys.contains(keyCode) {
            return keyUp(keyCode: keyCode)
        }
        heldKeys.insert(keyCode)
        return [.key(usage: usage, down: true)]
    }

    public mutating func buttonDown(_ button: RemoteMouseButton) -> [RemoteInputEvent] {
        heldButtons.insert(button)
        return [.button(button, down: true)]
    }

    public mutating func buttonUp(_ button: RemoteMouseButton) -> [RemoteInputEvent] {
        guard heldButtons.remove(button) != nil else { return [] }
        return [.button(button, down: false)]
    }

    /// Ups for everything held (focus lost, release chord, mode change).
    public mutating func releaseAll() -> [RemoteInputEvent] {
        let keys = heldKeys.sorted().flatMap { keyUp(keyCode: $0) }
        let buttons = heldButtons.sorted { $0.rawValue < $1.rawValue }.flatMap { buttonUp($0) }
        return keys + buttons
    }

    static let capsLock: UInt16 = 0x39

    /// The device-independent flag of a modifier key.
    static func family(of keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        default: nil
        }
    }
}
