extension ChatToolUse {
    /// Paths whose created provenance depends on a successful mutation result.
    var artifactMutationPaths: [String] {
        guard isArtifactMutation else { return [] }
        return referencedPaths ?? []
    }

    /// Whether this completed tool invocation authorizes created provenance.
    var authorizesCreatedArtifactProvenance: Bool {
        guard isArtifactMutation else { return false }
        return artifactMutationAuthorized == true
    }

    private var isArtifactMutation: Bool {
        let normalized = toolName.split(separator: ".").last.map(String.init) ?? toolName
        return normalized.lowercased() == "apply_patch"
    }
}
