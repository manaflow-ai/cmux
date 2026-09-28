import Foundation

/// Typed terminal conditions that affect automatic Cloud link admission.
/// Presentation still uses ``SurfaceMachineInfo.linkError`` for the localized
/// copy, while control flow reads this value instead of parsing that copy.
public enum SurfaceMachineLinkFailure: String, Codable, Sendable, Hashable {
    case recreateRequired
    case sessionRejected
}
