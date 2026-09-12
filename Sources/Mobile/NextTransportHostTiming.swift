#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Timing knobs for the parallel host's startup and lifecycle races.
enum NextTransportHostTiming {
    /// How long an accepted connection gets to complete the hello exchange
    /// before it is closed so it cannot wedge subsequent accepts.
    static let helloDeadlineSeconds: Int64 = 10
    /// How long a cached-credential relay handshake may hold up start();
    /// past this, startup proceeds and the relay comes up in the background.
    static let onlineDeadlineSeconds: Int64 = 10
    /// Max random jitter applied to scheduled credential refreshes so a
    /// fleet of hosts does not re-mint in lockstep.
    static let refreshJitterMaxSeconds: Int64 = 30
}
#endif
