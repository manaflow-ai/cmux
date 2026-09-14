import Foundation

/// Time bounds on one native cloud attachment. Every phase of the byte
/// attachment has a deadline, so a wedged socket (accepted by the daemon but
/// never answered, or silently stalled) is detected instead of waited on
/// forever.
struct CloudTuiManualMirrorDeadlines: Equatable, Sendable {
    /// The identify → set-client-info → attach handshake must complete within
    /// this bound, measured from the socket connect.
    let handshake: Duration
    /// While attached, a connection that delivered no frame for this long is
    /// probed with `ping`.
    let livenessInterval: Duration
    /// The probe must be answered within this bound or the attachment is
    /// declared stalled and reconnected.
    let livenessAnswer: Duration

    init(handshake: Duration, livenessInterval: Duration, livenessAnswer: Duration) {
        precondition(handshake > .zero)
        precondition(livenessInterval > .zero)
        precondition(livenessAnswer > .zero)
        self.handshake = handshake
        self.livenessInterval = livenessInterval
        self.livenessAnswer = livenessAnswer
    }

    /// Production bounds: generous enough for a cold link over a slow route,
    /// short enough that a user sees a reconnect instead of a dead pane.
    static let standard = Self(
        handshake: .seconds(20),
        livenessInterval: .seconds(30),
        livenessAnswer: .seconds(10)
    )
}
