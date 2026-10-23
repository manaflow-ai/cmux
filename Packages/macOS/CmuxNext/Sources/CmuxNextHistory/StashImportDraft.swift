public import Observation

/// One Stashed page's own state: its search text, and its OneTab paste box (Import from
/// OneTab…), inline, never a sheet, its own per window. The box closes when its page closes.
@Observable
public final class StashImportDraft {
    public var isOpen = false
    public var text = ""
    /// The page's search text (``StashPageModel/groups(matching:)``).
    public var query = ""

    public init() {}

    public func open() { isOpen = true }

    public func close() {
        isOpen = false
        text = ""
    }
}
