/// Runs a call inside a window that closes when the call returns or after a
/// bound on the injected clock, whichever comes first.
///
/// A page-world `frame.evaluate` is the session's own action: a dialog,
/// file chooser or window the page opens while it runs goes to the session.
/// A long evaluation must not keep that window open, or the user's own
/// dialogs and popups in that tab would go to the agent meanwhile; what a
/// script opens synchronously, or soon after, falls inside the bound.
@MainActor
public struct BrowserReplBoundedWindow {
    private let limit: Duration
    private let sleeper: any BrowserReplSleeping

    public init(limit: Duration, sleeper: any BrowserReplSleeping) {
        self.limit = limit
        self.sleeper = sleeper
    }

    /// - Parameters:
    ///   - begin: Opens the window, before `body` starts.
    ///   - end: Closes it, exactly once.
    public func run<T>(
        begin: () -> Void,
        end: @escaping @MainActor () -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let closer = Closer(end)
        begin()
        let sleeper = self.sleeper
        let limit = self.limit
        let deadline = Task { @MainActor in
            do {
                try await sleeper.sleep(for: limit)
            } catch {
                return
            }
            closer.close()
        }
        defer {
            deadline.cancel()
            closer.close()
        }
        return try await body()
    }
}

@MainActor
private final class Closer {
    private var end: (@MainActor () -> Void)?

    init(_ end: @escaping @MainActor () -> Void) {
        self.end = end
    }

    func close() {
        guard let end else { return }
        self.end = nil
        end()
    }
}
