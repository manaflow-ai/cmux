public import Foundation

/// Keys the daemon gave back from a terminal creation that did not take them (cx-wb5.78,
/// `terminal-input-unclaimed`), held until a terminal can take them: the focused one that is not
/// being created itself (a give-back can arrive while the failed creation's view still has focus).
@MainActor
public final class GivenBackInput {
    private var bytes = Data()

    public init() {}

    /// Adds `more`, then hands everything held to `target`, when there is one.
    public func deliver(adding more: Data = Data(), to target: (@MainActor (Data) -> Void)?) {
        bytes.append(more)
        guard !bytes.isEmpty, let target else { return }
        target(bytes)
        bytes = Data()
    }
}
