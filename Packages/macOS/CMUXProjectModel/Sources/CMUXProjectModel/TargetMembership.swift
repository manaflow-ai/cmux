import Foundation

/// The participation of one file in one target's build.
///
/// The same ``ProjectFileNode`` can carry multiple ``TargetMembership`` values
/// when it is built into more than one target (common for shared sources and
/// test helpers). Compiler flags are per-file-per-target Xcode build settings
/// stored on the `PBXBuildFile`'s `settings.COMPILER_FLAGS` array; the
/// navigator surfaces them as a small badge on the target chip.
public struct TargetMembership: Sendable, Hashable {
    public let targetID: TargetID
    public let role: TargetMembershipRole
    public let compilerFlags: [String]

    public init(
        targetID: TargetID,
        role: TargetMembershipRole,
        compilerFlags: [String] = []
    ) {
        self.targetID = targetID
        self.role = role
        self.compilerFlags = compilerFlags
    }
}
