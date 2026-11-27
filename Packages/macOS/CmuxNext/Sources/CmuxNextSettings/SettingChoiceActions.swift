public import CmuxNextActions

/// Palette actions that each set one choice of a cmux.json setting (a window
/// style, the animation speed): the shared shape, so the app supplies only
/// how a value is saved.
public nonisolated struct SettingChoiceActions: Sendable {
    /// Saves `value` at `path`: returns a refusal (the key is managed)
    /// before anything changes, else starts the cmux.json write and returns
    /// nil. The file watcher then reapplies the same value.
    public typealias Save = @MainActor (_ path: [String], _ value: JSONValue?) -> String?

    public init() {}

    /// Binds one action per value: a refused save is reported and changes
    /// nothing; otherwise `apply` sets the value at once. With `current`,
    /// each action also previews its value (`ActionRegistry.bindPreview`):
    /// the palette's highlighted row applies it without a write, and
    /// leaving the row applies `current()` as it was before the preview.
    @MainActor public static func bind<Value: Sendable>(
        _ values: [Value], into registry: ActionRegistry, id: (Value) -> String, path: [String],
        fileValue: @escaping (Value) -> JSONValue?, save: @escaping Save,
        current: (@MainActor () -> Value)? = nil, apply: @escaping @MainActor (Value) -> Void
    ) {
        for value in values {
            let actionID = ActionID(rawValue: id(value))
            registry.bind(actionID, invoke: { [weak registry] _ in
                if let refusal = save(path, fileValue(value)) {
                    registry?.endPreview()
                    registry?.refuse(refusal)
                    return
                }
                apply(value)
            })
            guard let current else { continue }
            registry.bindPreview(actionID, ActionPreview(group: path.joined(separator: ".")) {
                let before = current()
                apply(value)
                return { apply(before) }
            })
        }
    }
}
