import CmuxTerminalCore

/// Selects whether a new terminal inherits live font ownership or restores a snapshot.
enum TerminalFontSizeCreationPolicy: Equatable {
    /// Ordinary creation inherits the selected terminal's current font lineage.
    case inherit

    /// Session restoration treats the persisted override as authoritative.
    /// A nil or invalid value follows current config instead of inheriting a
    /// neighboring terminal's explicit zoom.
    case sessionRestore(overrideBasePoints: Float32?)

    /// Applies the policy without disturbing other inherited terminal config.
    func applying(to inheritedConfig: CmuxSurfaceConfigTemplate?) -> CmuxSurfaceConfigTemplate? {
        switch self {
        case .inherit:
            return inheritedConfig
        case .sessionRestore(let overrideBasePoints):
            guard let overrideBasePoints,
                  overrideBasePoints.isFinite,
                  overrideBasePoints > 0 else {
                guard var template = inheritedConfig else { return nil }
                template.fontSizeLineage = nil
                return template
            }
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.setFontSize(overrideBasePoints, isExplicitOverride: true)
            return template
        }
    }
}
