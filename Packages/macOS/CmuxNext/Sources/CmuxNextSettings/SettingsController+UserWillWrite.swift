extension SettingsController {
    /// Adds `hook` to ``userWillWrite``, after whatever is there already, so each owner of a
    /// per-Mac record (hang reports, usage recording) keeps its own and the order they start in
    /// does not matter. Each hook sees every write by the person; the chained undo runs every
    /// undo the hooks returned, the newest first, so a failed write leaves no record behind.
    ///
    /// ```swift
    /// settings.chainUserWillWrite { descriptor, value in
    ///     Self.recordUserWrite(defaults: defaults, path: descriptor.path, value: value)
    /// }
    /// ```
    ///
    /// - Parameter hook: Called before the person's write with its descriptor and value (nil:
    ///   removed); returns the undo for a write that then fails, or nil.
    public func chainUserWillWrite(_ hook: @escaping @MainActor (SettingDescriptor, JSONValue?) -> (@MainActor () -> Void)?) {
        guard let previous = userWillWrite else {
            userWillWrite = hook
            return
        }
        userWillWrite = { descriptor, value in
            let first = previous(descriptor, value)
            let second = hook(descriptor, value)
            switch (first, second) {
            case (nil, nil): return nil
            case (let undo?, nil), (nil, let undo?): return undo
            case (let first?, let second?): return { second(); first() }
            }
        }
    }
}
