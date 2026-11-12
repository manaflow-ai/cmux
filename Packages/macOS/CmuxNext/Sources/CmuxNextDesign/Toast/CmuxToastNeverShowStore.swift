public import Foundation

/// The toast kinds the person hid with Don't Show Again (``CmuxToast/kind``), kept in `defaults` so the
/// choice lasts across launches. Settings > Notifications > Show Hidden Toasts Again empties it
/// (``showAll()``).
///
/// The app makes one over `UserDefaults.standard` at its composition root and gives it to the shared
/// ``CmuxToastCenter``; tests pass a suite of their own.
///
/// ```swift
/// let store = CmuxToastNeverShowStore(defaults: .standard)
/// store.hide("terminal.selectionHint")
/// store.isHidden("terminal.selectionHint") // true, also after a relaunch
/// ```
@MainActor
public final class CmuxToastNeverShowStore {
    /// The defaults key that holds the hidden kinds, an array of strings.
    public static let defaultsKey = "cmux.toasts.neverShow"

    // UserDefaults is Apple-documented thread-safe; this store only touches it on the main actor.
    private nonisolated(unsafe) let defaults: UserDefaults?
    private var kinds: Set<String>

    /// - Parameter defaults: Where the hidden kinds persist; nil keeps them in memory only (a center
    ///   made before the app gives it its store, a headless run).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        kinds = Set(defaults?.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    /// Whether toasts of `kind` are hidden.
    public func isHidden(_ kind: String) -> Bool { kinds.contains(kind) }

    /// The hidden kinds, sorted.
    public var hiddenKinds: [String] { kinds.sorted() }

    /// Hides every toast of `kind` from now on.
    public func hide(_ kind: String) {
        guard kinds.insert(kind).inserted else { return }
        persist()
    }

    /// Shows every hidden kind again.
    public func showAll() {
        guard !kinds.isEmpty else { return }
        kinds.removeAll()
        persist()
    }

    private func persist() {
        if kinds.isEmpty { defaults?.removeObject(forKey: Self.defaultsKey) } else { defaults?.set(kinds.sorted(), forKey: Self.defaultsKey) }
    }
}
