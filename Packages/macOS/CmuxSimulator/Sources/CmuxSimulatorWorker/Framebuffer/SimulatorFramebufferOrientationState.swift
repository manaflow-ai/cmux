import CmuxSimulator

/// Reconciles SimulatorKit orientation metadata with IOSurface dimensions.
struct SimulatorFramebufferOrientationState: Equatable, Sendable {
    private(set) var orientation: SimulatorOrientation?
    private var requestedOrientation: SimulatorOrientation?

    mutating func reset() {
        orientation = nil
        requestedOrientation = nil
    }

    mutating func request(_ orientation: SimulatorOrientation) {
        self.orientation = orientation
        requestedOrientation = orientation
    }

    mutating func observe(
        width: Int,
        height: Int,
        nativeRawValue: UInt32?,
        nativeValueIsAuthoritative: Bool = false
    ) -> SimulatorOrientation {
        let nativeOrientation = nativeRawValue.flatMap(simulatorNativeOrientation(rawValue:))

        if let requestedOrientation {
            if let nativeOrientation,
               nativeOrientation == requestedOrientation || nativeValueIsAuthoritative {
                self.requestedOrientation = nil
                orientation = nativeOrientation
                return nativeOrientation
            }

            if nativeOrientation == nil,
               let landscapeShape = simulatorLandscapeShape(width: width, height: height),
               landscapeShape == simulatorOrientationIsLandscape(requestedOrientation) {
                self.requestedOrientation = nil
            }
            orientation = requestedOrientation
            return requestedOrientation
        }

        if let nativeOrientation {
            orientation = nativeOrientation
            return nativeOrientation
        }

        guard let landscapeShape = simulatorLandscapeShape(width: width, height: height) else {
            return orientation ?? .portrait
        }
        if let orientation,
           simulatorOrientationIsLandscape(orientation) == landscapeShape {
            return orientation
        }

        let inferred: SimulatorOrientation = landscapeShape ? .landscapeLeft : .portrait
        orientation = inferred
        return inferred
    }

}

/// Maps SimulatorKit's `SimScreenUIOrientation` values without importing its private type.
func simulatorNativeOrientation(rawValue: UInt32) -> SimulatorOrientation? {
    SimulatorNativeOrientationCodec.screenOrientation(rawValue: rawValue)
}

private func simulatorLandscapeShape(width: Int, height: Int) -> Bool? {
    guard width > 0, height > 0, width != height else { return nil }
    return width > height
}

private func simulatorOrientationIsLandscape(_ orientation: SimulatorOrientation) -> Bool {
    switch orientation {
    case .portrait, .portraitUpsideDown: false
    case .landscapeLeft, .landscapeRight: true
    }
}
