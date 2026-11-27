/// The even sizing of one split (`layout.splitSizing` = even) from the key that splits to the
/// daemon's reply (``LayoutModel/showSplitSizing(_:)``).
///
/// A split and the sizing that evens its chain are one gesture: the window shows both in the
/// key's frame, so every pane of the chain moves on the one spring, and the ratio intents go to
/// the daemon only once it made the split (``LayoutModel/commitSplitSizing(_:)``). A refused
/// split takes the sizing back (``LayoutModel/cancelSplitSizing(_:)``).
///
/// ```swift
/// let sizing = model.showSplitSizing(model.splitSizingChanges(splitting: pane, axis: .horizontal))
/// // ... the split's reply:
/// model.commitSplitSizing(sizing) // or model.cancelSplitSizing(sizing) when it failed
/// ```
public struct PendingSplitSizing: Hashable, Sendable {
    /// The ratio changes the split's chain needs (empty for `halve` sizing).
    public let changes: [SplitRatioChange]
    /// The one transaction every change of this gesture carries.
    let transaction: LayoutTransactionID
}
