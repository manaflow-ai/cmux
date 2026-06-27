public import Combine
public import Foundation

extension Notification.Name {
    /// Broadcast whenever the notifications popover is shown or hidden in any window.
    ///
    /// The posted `userInfo` carries the aggregate `isShown` flag under the
    /// `"isShown"` key and, when a window-scoped change drove the post, the
    /// affected `windowNumber` under the `"windowNumber"` key.
    public static let cmuxNotificationsPopoverVisibilityDidChange = Notification.Name("cmux.notificationsPopoverVisibilityDidChange")
}

/// Process-wide pub/sub state machine tracking whether the notifications popover
/// is currently visible, scoped per window.
///
/// Sources that show or hide a popover register themselves by identity
/// (`AnyObject`) plus an optional `windowNumber`; the aggregate `isShown` flag is
/// `true` while any source (or a source-less show) is active, and
/// ``shownWindowNumbers`` projects the set of windows with a visible popover so
/// per-window chrome can stay revealed.
///
/// Isolation: the type stays a non-`@MainActor` `ObservableObject` and is marked
/// `@unchecked Sendable` to preserve the legacy app-target behavior byte-for-byte.
/// All mutations are funneled to the main thread (``setShown(_:source:windowNumber:)``
/// hops via `DispatchQueue.main.async` when called off-main, and the actual state
/// edit happens in `setShownOnMain`), while ``isShown(in:)`` performs a small,
/// unguarded value read from any thread exactly as the original did. The
/// `@Published` projected publishers (`$isShown`, `$shownWindowNumbers`) and the
/// `@ObservedObject` SwiftUI consumers are kept on Combine rather than migrated to
/// `@Observable`, since that consumer migration is behavior-affecting and out of
/// scope for this faithful relocation.
public final class NotificationsPopoverVisibilityState: ObservableObject, @unchecked Sendable {
    /// The shared process-wide visibility bus. A single instance backs every
    /// popover and every consumer so the aggregate flag and per-window set stay
    /// consistent across windows.
    public static let shared = NotificationsPopoverVisibilityState()

    /// Whether any notifications popover is currently shown.
    @Published public private(set) var isShown = false
    /// The set of window numbers that currently have a visible notifications popover.
    @Published public private(set) var shownWindowNumbers: Set<Int> = []
    private var shownPopoverIDs: Set<ObjectIdentifier> = []
    private var shownPopoverWindowNumbers: [ObjectIdentifier: Int] = [:]
    private var sourceLessShown = false

    private static let userInfoKeyIsShown = "isShown"
    private static let userInfoKeyWindowNumber = "windowNumber"

    private init() {}

    /// Sets the source-less aggregate visibility, clearing any per-source state.
    public func setShown(_ newValue: Bool) {
        setShown(newValue, source: nil, windowNumber: nil)
    }

    /// Records that `source` is showing (or, when `newValue` is `false`, no longer
    /// showing) a popover in `windowNumber`, hopping to the main thread if needed.
    /// A `nil` `source` sets the source-less aggregate and clears per-source state.
    public func setShown(_ newValue: Bool, source: AnyObject?, windowNumber: Int? = nil) {
        // Reduce the source to its `Sendable` identity before any actor hop so a
        // non-`Sendable` `AnyObject` never crosses into the main-actor closure.
        // `setShownOnMain` only ever used the source for `ObjectIdentifier`, so
        // this is behavior-identical.
        let sourceID = source.map(ObjectIdentifier.init)
        if Thread.isMainThread {
            setShownOnMain(newValue, sourceID: sourceID, windowNumber: windowNumber)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setShownOnMain(newValue, sourceID: sourceID, windowNumber: windowNumber)
            }
        }
    }

    /// Whether a popover is shown in `windowNumber`. A `nil` window number returns
    /// the aggregate ``isShown`` flag.
    public func isShown(in windowNumber: Int?) -> Bool {
        guard let windowNumber else { return isShown }
        return sourceLessShown || shownWindowNumbers.contains(windowNumber)
    }

    /// Updates the shared visibility state for `source`/`windowNumber` and posts
    /// ``Foundation/Notification/Name/cmuxNotificationsPopoverVisibilityDidChange``
    /// with the resulting aggregate `isShown` flag (and `windowNumber` when one
    /// was supplied) in `userInfo`.
    public func setShownAndPost(isShown: Bool, source: AnyObject? = nil, windowNumber: Int? = nil) {
        setShown(isShown, source: source, windowNumber: windowNumber)
        var userInfo: [String: Any] = [Self.userInfoKeyIsShown: self.isShown]
        if let windowNumber {
            userInfo[Self.userInfoKeyWindowNumber] = windowNumber
        }
        NotificationCenter.default.post(
            name: .cmuxNotificationsPopoverVisibilityDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    private func setShownOnMain(_ newValue: Bool, sourceID: ObjectIdentifier?, windowNumber: Int?) {
        if let id = sourceID {
            if newValue {
                shownPopoverIDs.insert(id)
                if let windowNumber {
                    shownPopoverWindowNumbers[id] = windowNumber
                }
            } else {
                shownPopoverIDs.remove(id)
                shownPopoverWindowNumbers.removeValue(forKey: id)
            }
        } else {
            shownPopoverIDs.removeAll()
            shownPopoverWindowNumbers.removeAll()
            sourceLessShown = newValue
        }
        updateShown()
    }

    private func updateShown() {
        let newWindowNumbers = Set(shownPopoverWindowNumbers.values)
        if shownWindowNumbers != newWindowNumbers {
            shownWindowNumbers = newWindowNumbers
        }
        let newValue = sourceLessShown || !shownPopoverIDs.isEmpty
        guard isShown != newValue else { return }
        isShown = newValue
    }

    #if DEBUG
    /// Clears all visibility state. Test-only.
    public func resetForTesting() {
        shownPopoverIDs.removeAll()
        shownPopoverWindowNumbers.removeAll()
        sourceLessShown = false
        updateShown()
    }
    #endif
}
