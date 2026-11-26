import Foundation

extension UserDefaultsSettingsStore {
    /// Returns shortcut overrides written by the legacy UserDefaults-backed Settings UI.
    ///
    /// Callers merge this snapshot below `cmux.json` bindings and above built-in defaults,
    /// matching the app's compatibility lookup order.
    public nonisolated func initialLegacyShortcutBindings() -> [String: StoredShortcut] {
        let decoder = JSONDecoder()
        return Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            let key = legacyShortcutKey(for: action)
            guard let data = storage.valueIfPresent(for: key),
                  let payload = try? decoder.decode(LegacyStoredShortcutPayload.self, from: data) else {
                return nil
            }
            return (action.rawValue, payload.storedShortcut)
        })
    }

    /// Returns the current legacy shortcut overrides and later UserDefaults changes.
    public nonisolated func legacyShortcutBindingValues() -> AsyncStream<[String: StoredShortcut]> {
        let storage = self.storage
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = storage.addDidChangeObserver { _, _ in signalContinuation.yield() }
            let drainTask = Task { [weak self] in
                guard let initial = self?.initialLegacyShortcutBindings() else {
                    continuation.finish()
                    return
                }
                var lastYielded = initial
                continuation.yield(lastYielded)
                for await _ in signals {
                    if Task.isCancelled { break }
                    guard let current = self?.initialLegacyShortcutBindings() else { break }
                    guard current != lastYielded else { continue }
                    lastYielded = current
                    continuation.yield(current)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// Removes the legacy UserDefaults override after an authoritative JSON binding is saved.
    ///
    /// - Parameter action: The shortcut action whose legacy value should be removed.
    public func resetLegacyShortcutBinding(for action: ShortcutAction) {
        let key = legacyShortcutKey(for: action)
        guard storage.hasStoredValue(for: key.userDefaultsKey) else { return }
        reset(key)
    }

    /// Removes every legacy UserDefaults shortcut override after JSON defaults are reset.
    public func resetAllLegacyShortcutBindings() {
        for action in ShortcutAction.allCases {
            resetLegacyShortcutBinding(for: action)
        }
    }

    private nonisolated func legacyShortcutKey(
        for action: ShortcutAction
    ) -> DefaultsKey<Data> {
        DefaultsKey(
            id: "shortcuts.legacy.\(action.rawValue)",
            defaultValue: Data(),
            userDefaultsKey: "shortcut.\(action.rawValue)"
        )
    }
}
