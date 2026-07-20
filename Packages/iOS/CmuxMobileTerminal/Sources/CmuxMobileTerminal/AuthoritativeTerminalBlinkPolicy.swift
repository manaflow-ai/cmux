extension AuthoritativeTerminalGridView {
    nonisolated static func shouldDrawText(styleBlinks: Bool, blinkPhaseVisible: Bool) -> Bool {
        !styleBlinks || blinkPhaseVisible
    }
}
