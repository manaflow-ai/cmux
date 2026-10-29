/// A live preview of an action before it runs: the palette's highlighted
/// "Window Style: Card" row shows that style in the window without writing
/// cmux.json. `show` applies the look at once and returns how to put the
/// previous look back. Previews of one `group` (one setting) replace each
/// other in place: moving from Card to Flat applies Flat and keeps Card's
/// revert to the committed value, so each move is one cheap write.
public struct ActionPreview {
    public var group: String
    public var show: @MainActor () -> @MainActor () -> Void

    public init(group: String, show: @escaping @MainActor () -> @MainActor () -> Void) {
        self.group = group
        self.show = show
    }
}

/// The preview on screen now: its action, group and the revert to the look
/// before the group's first preview.
struct ActivePreview {
    var id: ActionID
    var group: String
    var revert: @MainActor () -> Void
}

extension ActionRegistry {
    /// Makes `id` previewable (`showPreview`).
    public func bindPreview(_ id: ActionID, _ preview: ActionPreview) {
        previews[canonicalID(for: id)] = preview
    }

    public func hasPreview(_ id: ActionID) -> Bool {
        previews[canonicalID(for: id)] != nil
    }

    /// The action previewed now, if any.
    public var previewedAction: ActionID? { activePreview?.id }

    /// Shows the preview of `id`; nil, or an action with no preview, ends
    /// the one on screen (the highlight moved to another row).
    public func showPreview(_ id: ActionID?) {
        guard let id = id.map(canonicalID(for:)), let preview = previews[id] else { return endPreview() }
        guard id != activePreview?.id else { return }
        if let active = activePreview, active.group == preview.group {
            _ = preview.show()
            activePreview?.id = id
            return
        }
        endPreview()
        activePreview = ActivePreview(id: id, group: preview.group, revert: preview.show())
    }

    /// Puts the committed look back (Escape, the palette closed, a refused run).
    public func endPreview() {
        guard let active = activePreview else { return }
        activePreview = nil
        active.revert()
    }

    /// Runs `perform` for `id` with the preview settled: running the
    /// previewed action keeps its look (the run sets the same value; a
    /// handler that refuses calls `endPreview`), running anything else, or
    /// a run that did not happen, reverts.
    ///
    /// `perform` gets `settle`, which it calls inside the run's timing (or its gate's), before
    /// the work: putting the look back is part of what the person waits for, so it is in
    /// `action.perform` / `action.commit`. A refused run never calls it and records nothing; its
    /// revert happens after.
    func settlingPreview(for id: ActionID, _ perform: (_ settle: () -> Void) -> Bool) -> Bool {
        guard let previewed = activePreview?.id else { return perform {} }
        guard previewed == canonicalID(for: id) else {
            let ran = perform { endPreview() }
            endPreview()
            return ran
        }
        let ran = perform {}
        if activePreview?.id == previewed {
            if ran { activePreview = nil } else { endPreview() }
        }
        return ran
    }
}
