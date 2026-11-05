public import CmuxTheme
public import CmuxNextDesignTokens

/// Renders the identity tone chosen by shared web `agentTone(id)`. Native surfaces never hash
/// the id again; these ANSI indices and ink shares match subagents.css.
public nonisolated enum AgentIdentityTone {
    public static func valid(_ tone: Int?) -> Int? {
        tone.flatMap { (0..<5).contains($0) ? $0 : nil }
    }

    public static func rgb(_ tone: Int?, tokens: ThemeTokens) -> ThemeRGB? {
        guard let tone = valid(tone) else { return nil }
        let index = [2, 5, 3, 6, 13][tone]
        guard tokens.ansi.indices.contains(index) else { return nil }
        return tokens.ansi[index].mixed(toward: tokens.textPrimary, tokens.isDark ? 0.28 : 0.42)
    }
}
