import CoreGraphics

/// Injectable window metadata reads; production uses public Core Graphics APIs.
struct ExternalApplicationWindowDependencies: Sendable {
    let frontWindow: @Sendable (pid_t, CGFloat) -> ExternalApplicationWindowSnapshot?
    let window: @Sendable (CGWindowID, pid_t, CGFloat) -> ExternalApplicationWindowSnapshot?

    static let live = ExternalApplicationWindowDependencies(
        frontWindow: { processIdentifier, primaryScreenMaxY in
            ExternalApplicationWindowTracker.frontWindowSnapshot(
                processIdentifier: processIdentifier,
                primaryScreenMaxY: primaryScreenMaxY
            )
        },
        window: { windowID, processIdentifier, primaryScreenMaxY in
            ExternalApplicationWindowTracker.windowSnapshot(
                windowID: windowID,
                processIdentifier: processIdentifier,
                primaryScreenMaxY: primaryScreenMaxY
            )
        }
    )
}
