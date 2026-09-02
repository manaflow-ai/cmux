import Foundation

extension CmuxConfigFile {
    /// Decodes one preprocessed JSONC payload and applies the shared command
    /// validator used by the app and Vault registry paths.
    static func decodeAndValidate(
        sanitizedData: Data,
        workspaceColorPalette: [String: String]
    ) throws -> CmuxConfigDecodedResult {
        let decoder = JSONDecoder()
        decoder.userInfo[.cmuxWorkspaceColorPalette] = workspaceColorPalette
        let config = try decoder.decode(Self.self, from: sanitizedData)
        let validatorIssues = (try? CmuxConfigTypeValidator(
            // The validator normalizes names for the same case-insensitive
            // lookup used by the runtime palette resolver.
            workspaceColorNames: Set(workspaceColorPalette.keys.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
        ).issues(in: sanitizedData)) ?? []
        return CmuxConfigDecodedResult(
            config: config,
            typeIssues: CmuxConfigTypeIssue.merged(
                config.commandDecodingIssues,
                with: validatorIssues
            )
        )
    }
}
