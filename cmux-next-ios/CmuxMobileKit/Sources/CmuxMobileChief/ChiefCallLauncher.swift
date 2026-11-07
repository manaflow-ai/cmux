import Foundation
import Observation

/// One path for every "Call Chief" entry point: Chief info's Call action,
/// Home's Chief row menu, the Action Button and Siri. The signed-in shell installs ``handler`` (start the live
/// call, or open Settings → Chief Calls when no OpenAI key is set); a call
/// asked for before that (a cold launch from the Action Button) waits for it.
///
/// A call names the Chief it is to: the one whose row or info page was tapped. The call is
/// scoped to that Chief only (Aziz 2026-11-05: a call to one Chief saw only the Cloud Chief).
/// Nil (the Action Button, Siri, Settings) is the default Chief, ``ChiefSources/primary``.
@MainActor
@Observable
public final class ChiefCallLauncher {
    public static let shared = ChiefCallLauncher()

    /// Starts or shows the call; set by the shell while it is on screen.
    @ObservationIgnored public var handler: (@MainActor (ChiefSession?) -> Void)? {
        didSet {
            guard handler != nil, let asked = pendingSince else { return }
            let chief = pendingChief
            pendingSince = nil
            pendingChief = nil
            // Only a call asked for moments ago (a cold launch from the Action Button):
            // never start a billed call minutes later, after sign-in or setup.
            guard now().timeIntervalSince(asked) < Self.pendingWindow else { return }
            handler?(chief)
        }
    }

    /// When a call was asked for before the shell was up, and to which Chief.
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private var pendingChief: ChiefSession?
    @ObservationIgnored private let now: () -> Date
    static let pendingWindow: TimeInterval = 20

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Calls `chief`, or the default Chief when nil.
    public func call(_ chief: ChiefSession? = nil) {
        guard let handler else {
            pendingSince = now()
            pendingChief = chief
            return
        }
        handler(chief)
    }

    /// Drops a call asked for while signed out.
    public func cancelPending() {
        pendingSince = nil
        pendingChief = nil
    }
}
