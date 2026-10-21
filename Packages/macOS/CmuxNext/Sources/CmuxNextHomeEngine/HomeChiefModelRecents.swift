public import Foundation

/// The models the person last picked for a Chief, per harness, newest first: the Model popup's
/// Recent section. The app passes its `UserDefaults`; without one the list lasts as long as the
/// object (a test, or a card made before the app wires it).
@MainActor
public final class HomeChiefModelRecents {
    static let key = "home.chief.recentModels"
    static let limit = 5
    // UserDefaults is Apple-documented thread-safe; this type reads and writes it on the main actor only.
    private let defaults: UserDefaults?
    private var memory: [String: [String]] = [:]

    /// - Parameter defaults: where the list is kept across launches; nil keeps it in memory.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    /// The models picked on `harness`, newest first.
    public func models(harness: String) -> [String] {
        stored()[harness] ?? []
    }

    /// Puts `model` first in `harness`'s list, once, and keeps the list short.
    public func remember(_ model: String, harness: String) {
        var all = stored()
        all[harness] = Array(([model] + (all[harness] ?? []).filter { $0 != model }).prefix(Self.limit))
        memory = all
        defaults?.set(all, forKey: Self.key)
    }

    private func stored() -> [String: [String]] {
        guard let defaults else { return memory }
        return defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }
}
