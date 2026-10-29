public import CmuxTheme
public import CmuxNextDesignTokens

/// A machine's picked color in a theme's palette: an accent follows the theme as the automatic
/// color does (`AgentPresenceColor`).
nonisolated extension MachineColorOverrides {
    /// The color picked for the machine keyed `key`, in `tokens`' palette; nil without a pick.
    public func rgb(forKey key: String, tokens: ThemeTokens) -> ThemeRGB? {
        switch picks[key] {
        case .accent(let accent)?: AgentPresenceColor.rgb(of: accent, tokens: tokens)
        case .rgb(let rgb)?: rgb
        case nil: nil
        }
    }
}
