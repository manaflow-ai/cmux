/// Runtime state of an Android Virtual Device known to the installed SDK.
public enum AndroidVirtualDeviceState: Sendable, Equatable {
    /// The AVD is available but is not connected to Android Debug Bridge.
    case stopped

    /// Android Debug Bridge could not authoritatively determine whether the AVD is running.
    case unavailable

    /// The AVD is connected through Android Debug Bridge.
    case running(serial: String, connectionState: String, transportID: String)

    /// The Android Debug Bridge serial when the AVD is running.
    public var serial: String? {
        guard case .running(let serial, _, _) = self else { return nil }
        return serial
    }

    /// The non-reusable Android Debug Bridge transport identity when the AVD is running.
    public var transportID: String? {
        guard case .running(_, _, let transportID) = self else { return nil }
        return transportID
    }

    /// Whether Android Debug Bridge currently reports the AVD.
    public var isRunning: Bool {
        serial != nil
    }
}
