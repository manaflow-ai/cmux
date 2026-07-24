/// Selects how a new terminal surface obtains its initial font-size lineage.
public enum TerminalFontSizeCreationPolicy: Equatable, Sendable {
    /// Preserves the inherited terminal configuration, including its font-size lineage.
    case inherit

    /// Restores an explicit persisted font-size override or clears inherited lineage.
    ///
    /// A missing value or one outside ``TerminalFontSizePolicy``'s persistable
    /// base range clears inherited lineage so the surface follows current config.
    ///
    /// - Parameter overrideBasePoints: The persisted unscaled base font size, or
    ///   `nil` when the restored surface had no explicit override.
    case sessionRestore(overrideBasePoints: Float32?)

    /// Applies the creation policy while preserving unrelated inherited configuration.
    ///
    /// - Parameter inheritedConfig: The configuration inherited from the selected
    ///   terminal, or `nil` when no inheritable configuration is available.
    /// - Returns: The configuration for the new terminal, or `nil` when no template
    ///   is needed.
    public func applying(
        to inheritedConfig: CmuxSurfaceConfigTemplate?
    ) -> CmuxSurfaceConfigTemplate? {
        switch self {
        case .inherit:
            return inheritedConfig
        case .sessionRestore(let overrideBasePoints):
            guard let overrideBasePoints,
                  TerminalFontSizePolicy().acceptsPersistedBasePoints(overrideBasePoints) else {
                guard var template = inheritedConfig else { return nil }
                template.fontSizeLineage = nil
                template.fontSizeChangeToken = nil
                return template
            }
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.setFontSize(overrideBasePoints, isExplicitOverride: true)
            return template
        }
    }
}
