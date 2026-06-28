import Foundation

extension CodingUserInfoKey {
    /// Decoder `userInfo` key carrying the `UserDefaults` whose effective palette
    /// resolves named workspace colors during `CmuxWorkspaceDefinition` decode.
    /// Absent in production decode (which falls back to `.standard`); set by tests
    /// to inject a scoped suite.
    public static let cmuxWorkspaceColorDefaults = CodingUserInfoKey(rawValue: "cmuxWorkspaceColorDefaults")!
}
