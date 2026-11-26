/// Ordered pending-dialog state whose removal operation is the exactly-once claim.
public struct MobileBrowserDialogQueue: Equatable, Sendable {
    private var dialogs: [MobileBrowserDialogEvent] = []

    /// Creates an empty pending-dialog queue.
    public init() {}

    /// The oldest unresolved dialog for late-attaching subscribers.
    public var current: MobileBrowserDialogEvent? { dialogs.first }

    /// Every unresolved dialog in presentation order.
    public var pending: [MobileBrowserDialogEvent] { dialogs }

    /// Adds a dialog if its UUID is not already pending.
    /// - Parameter dialog: Dialog to add.
    /// - Returns: `true` when the dialog became pending.
    @discardableResult
    public mutating func install(_ dialog: MobileBrowserDialogEvent) -> Bool {
        guard !dialogs.contains(where: { $0.dialogID == dialog.dialogID }) else { return false }
        dialogs.append(dialog)
        return true
    }

    /// Atomically claims one dialog for resolution by removing it.
    /// - Parameter dialogID: UUID string of the dialog to claim.
    /// - Returns: The claimed dialog, or `nil` when another resolver already won.
    @discardableResult
    public mutating func claim(dialogID: String) -> MobileBrowserDialogEvent? {
        guard let index = dialogs.firstIndex(where: { $0.dialogID == dialogID }) else { return nil }
        return dialogs.remove(at: index)
    }

    /// Claims matching dialogs in one pass before any completion can run.
    /// - Parameter predicate: Selects dialogs to claim; defaults to all dialogs.
    /// - Returns: Dialogs claimed in presentation order.
    public mutating func claimAll(
        where predicate: (MobileBrowserDialogEvent) -> Bool = { _ in true }
    ) -> [MobileBrowserDialogEvent] {
        var claimed: [MobileBrowserDialogEvent] = []
        var remaining: [MobileBrowserDialogEvent] = []
        for dialog in dialogs {
            if predicate(dialog) {
                claimed.append(dialog)
            } else {
                remaining.append(dialog)
            }
        }
        dialogs = remaining
        return claimed
    }
}
