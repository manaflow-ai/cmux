import Foundation
import Observation

/// One path for every "Call Chief" entry point: Chief info's Call action,
/// Home's Chief row menu, the Action Button and Siri. The signed-in shell installs ``handler`` (start the live
/// call, or open Settings → Chief Calls when no OpenAI key is set); a call
/// asked for before that (a cold launch from the Action Button) waits for it.
@MainActor
@Observable
public final class ChiefCallLauncher {
    public static let shared = ChiefCallLauncher()

    /// Starts or shows the call; set by the shell while it is on screen.
    @ObservationIgnored public var handler: (@MainActor () -> Void)? {
        didSet {
            guard handler != nil, let asked = pendingSince else { return }
            pendingSince = nil
            // Only a call asked for moments ago (a cold launch from the Action Button):
            // never start a billed call minutes later, after sign-in or setup.
            guard now().timeIntervalSince(asked) < Self.pendingWindow else { return }
            handler?()
        }
    }

    /// When a call was asked for before the shell was up.
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private let now: () -> Date
    static let pendingWindow: TimeInterval = 20

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    public func call() {
        guard let handler else {
            pendingSince = now()
            return
        }
        handler()
    }

    /// Drops a call asked for while signed out.
    public func cancelPending() {
        pendingSince = nil
    }
}
