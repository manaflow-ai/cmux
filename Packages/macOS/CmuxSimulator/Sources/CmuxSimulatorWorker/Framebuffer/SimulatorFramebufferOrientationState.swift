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
        let nativeOrientation = nativeRawValue.flatMap(Self.nativeOrientation(rawValue:))

        if let requestedOrientation {
            if let nativeOrientation,
               nativeOrientation == requestedOrientation || nativeValueIsAuthoritative {
                self.requestedOrientation = nil
                orientation = nativeOrientation
                return nativeOrientation
            }

            if nativeOrientation == nil,
               let landscapeShape = Self.landscapeShape(width: width, height: height),
               landscapeShape == Self.isLandscape(requestedOrientation) {
                self.requestedOrientation = nil
            }
            orientation = requestedOrientation
            return requestedOrientation
        }

        if let nativeOrientation {
            orientation = nativeOrientation
            return nativeOrientation
        }

        guard let landscapeShape = Self.landscapeShape(width: width, height: height) else {
            return orientation ?? .portrait
        }
        if let orientation,
           Self.isLandscape(orientation) == landscapeShape {
            return orientation
        }

        let inferred: SimulatorOrientation = landscapeShape ? .landscapeLeft : .portrait
        orientation = inferred
        return inferred
    }

    /// Maps SimulatorKit's `SimScreenUIOrientation` values without importing its private type.
    static func nativeOrientation(rawValue: UInt32) -> SimulatorOrientation? {
        switch rawValue {
        case 1: .portrait
        case 2: .portraitUpsideDown
        case 3: .landscapeRight
        case 4: .landscapeLeft
        default: nil
        }
    }

    private static func landscapeShape(width: Int, height: Int) -> Bool? {
        guard width > 0, height > 0, width != height else { return nil }
        return width > height
    }

    private static func isLandscape(_ orientation: SimulatorOrientation) -> Bool {
        switch orientation {
        case .portrait, .portraitUpsideDown: false
        case .landscapeLeft, .landscapeRight: true
        }
    }
}
