import Foundation

/// Presence-aware values decoded from the `inlineVSCode` block of `cmux.json`.
///
/// `nil` means the key was absent from the file, which lets
/// ``InlineVSCodeServeWebOptionsResolver`` fall back to the environment and then
/// internal defaults. Distinguishing "absent" from "set to the default value" is
/// exactly why this type carries optionals instead of reusing
/// ``InlineVSCodeServeWebOptions``.
struct InlineVSCodeConfigFileValues: Equatable, Sendable {
    var port: Int?
    var serverDataDir: String?
    var persistServeWebState: Bool?
    var extraArgs: [String]?

    static let empty = InlineVSCodeConfigFileValues(
        port: nil,
        serverDataDir: nil,
        persistServeWebState: nil,
        extraArgs: nil
    )
}
