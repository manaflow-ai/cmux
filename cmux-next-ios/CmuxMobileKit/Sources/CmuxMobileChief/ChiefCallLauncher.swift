import Foundation
import Observation

/// One path for every "Call Chief" entry point: the conversation header's
/// phone button, Chief info's Call action, Home's Chief row menu, the Action
/// Button and Siri. The signed-in shell installs ``handler`` (start the live
/// call, or open Settings → Chief Calls when no OpenAI key is set); a call
/// asked for before that (a cold launch from the Action Button) waits for it.
@MainActor
@Observable
public final class ChiefCallLauncher {
    public static let shared = ChiefCallLauncher()

    /// Starts or shows the call; set by the shell while it is on screen.
    @ObservationIgnored public var handler: (@MainActor () -> Void)? {
        didSet {
            guard handler != nil, pending else { return }
            pending = false
            handler?()
        }
    }

    /// A call was asked for before the shell was up.
    @ObservationIgnored private var pending = false

    public init() {}

    public func call() {
        guard let handler else {
            pending = true
            return
        }
        handler()
    }
}
