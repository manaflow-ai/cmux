import Foundation

/// An experimental source projected into the simulated device camera.
public enum SimulatorCameraConfiguration: Codable, Hashable, Sendable {
    /// Disable the synthetic camera source.
    case disabled
    /// Present the worker's generated placeholder frame.
    case placeholder
    /// Repeatedly present one still image.
    case image(URL)
    /// Present a video file, optionally looping at its end.
    case video(URL, loops: Bool)
    /// Project a host camera selected by its unique identifier.
    case hostCamera(deviceID: String?)
    /// Apply a source to one installed target app instead of inferring the
    /// foreground application.
    indirect case targeted(bundleIdentifier: String, source: SimulatorCameraConfiguration)
}

extension SimulatorCameraConfiguration {
    /// Whether this configuration disables camera injection.
    public var isDisabled: Bool {
        switch self {
        case .disabled:
            true
        case let .targeted(_, source):
            source.isDisabled
        default:
            false
        }
    }

    /// The explicit target bundle identifier, when supplied.
    public var targetBundleIdentifier: String? {
        if case let .targeted(bundleIdentifier, _) = self { return bundleIdentifier }
        return nil
    }
}
