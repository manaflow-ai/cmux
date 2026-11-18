public import CmuxNextPalette
import Foundation

extension AgentPaneOmnibar {
    /// The bar's pick history (``uses``) from the Commands palette's: each usage key of a kind of row that the
    /// bar lists (`tab:`, `workspace:`, `action:`) with its decayed score, when it has uses.
    ///
    /// The scores are read at the start of the clock's minute. They decay with the clock, and the history is in
    /// the part of a New Tab context that the pages share (``AgentPaneNewTabShared``): scores read at each key's
    /// own time gave each page of a held New Tab key its own text of that part. A minute is 0.02 % of a score at
    /// the half-life of 3 days, and each key decays by the same factor, so the order of the keys stays.
    @MainActor public static func uses(of palette: PaletteModel) -> [String: Double] {
        let now = Date(timeIntervalSinceReferenceDate: (palette.now().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let history = palette.frecency
        var uses: [String: Double] = [:]
        for key in history.entries.keys where key.hasPrefix("tab:") || key.hasPrefix("workspace:") || key.hasPrefix("action:") {
            let score = history.score(for: key, at: now)
            if score > 0.01 { uses[key] = score }
        }
        return uses
    }
}
