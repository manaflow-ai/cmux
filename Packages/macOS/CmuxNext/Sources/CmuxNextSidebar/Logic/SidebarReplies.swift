import Foundation

/// The replies of one sidebar change's commands, each sent on its own (#26382): `failed` at the first failure (once),
/// else `applied` once every command's result is held (`applied()` per command). A change that failed already took
/// its edit back, so a later success does nothing.
@MainActor
public final class SidebarReplies<Failure> {
    private var left: Int
    private var onFailure: (@MainActor (Failure) -> Void)?
    private let onApplied: (@MainActor () -> Void)?

    public init(_ count: Int, failed: @escaping @MainActor (Failure) -> Void, applied: (@MainActor () -> Void)?) {
        left = count
        onFailure = failed
        onApplied = applied
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050).
    nonisolated deinit {}

    public func failed(_ failure: Failure) {
        let report = onFailure
        onFailure = nil
        report?(failure)
    }

    public func applied() {
        left -= 1
        if left == 0, onFailure != nil { onApplied?() }
    }
}
