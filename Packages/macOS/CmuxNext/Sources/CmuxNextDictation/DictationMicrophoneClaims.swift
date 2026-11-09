import Foundation

/// The one microphone the app's dictation surfaces share: the agent panes'
/// composers and Home's message box. A surface claims it when it starts
/// listening; a claim from another surface first stops the holder's session
/// (keeping its words), so at most one listens at a time. The holder gives
/// it back when its session ends.
@MainActor
public final class DictationMicrophoneClaims {
    /// The app's claims (tests make their own).
    public static let shared = DictationMicrophoneClaims()

    private weak var holder: AnyObject?
    private var stopHolder: (@MainActor () -> Void)?
    /// Told after each claim, release and yield (``MicrophoneActivity`` closes its meter on a claim).
    private var observers: [ObjectIdentifier: @MainActor () -> Void] = [:]

    public init() {}

    /// `owner` hears each change of holder, after it applies, until ``unobserve(_:)``.
    public func observe(_ owner: AnyObject, onChange: @escaping @MainActor () -> Void) {
        observers[ObjectIdentifier(owner)] = onChange
    }

    /// `owner` no longer hears changes.
    public func unobserve(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func changed() {
        for observer in Array(observers.values) { observer() }
    }

    /// `owner` starts listening: whoever else holds the microphone stops first.
    /// - Parameters:
    ///   - owner: The surface that listens now (held weakly).
    ///   - stop: Stops `owner`'s session, keeping its words; run when another surface claims.
    public func claim(_ owner: AnyObject, stop: @escaping @MainActor () -> Void) {
        if let holder, holder !== owner {
            let previous = stopHolder
            stopHolder = nil
            self.holder = nil
            previous?()
        }
        holder = owner
        stopHolder = stop
        // Before the claimer opens its engine: an outside-dictation meter closes now.
        changed()
    }

    /// `owner`'s session ended; a claim held by someone else stays.
    public func release(_ owner: AnyObject) {
        guard holder === owner else { return }
        holder = nil
        stopHolder = nil
        changed()
    }

    /// Stops whoever holds the microphone, keeping their words: another app takes it now (the
    /// composer mic's hand-off to a dictation app).
    public func yield() {
        let previous = stopHolder
        (holder, stopHolder) = (nil, nil)
        previous?()
        changed()
    }

    /// Whether any of cmux's surfaces holds the microphone now.
    public var isHeld: Bool { holder != nil }

    /// Whether `owner` holds the microphone now.
    public func isHeld(by owner: AnyObject) -> Bool { holder === owner }
}
