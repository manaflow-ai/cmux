import Foundation

/// The build phase a file participates in for a given target.
///
/// Derived from the Xcode build-phase isa (`PBXSourcesBuildPhase`,
/// `PBXResourcesBuildPhase`, etc.). Used by the navigator to render
/// target-membership chips that distinguish "compiled source" from "copied
/// resource", and by the future editing path to know which phase to mutate
/// when toggling membership.
public enum TargetMembershipRole: String, Sendable, Hashable, Codable {
    case compile
    case resource
    case copy
    case framework
    case header
    case script
}
