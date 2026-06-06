import AppKit
import Foundation

struct QuickTerminalConfiguration: Equatable {
    static let fallback = QuickTerminalConfiguration(
        position: .top,
        screenFraction: 0.46,
        animationDuration: 0.18
    )

    var position: QuickTerminalPosition
    var screenFraction: CGFloat
    var animationDuration: TimeInterval

    init(
        position: QuickTerminalPosition,
        screenFraction: CGFloat,
        animationDuration: TimeInterval
    ) {
        self.position = position
        self.screenFraction = min(max(screenFraction, 0.2), 0.95)
        self.animationDuration = min(max(animationDuration, 0.05), 0.6)
    }

    static func current(loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() }) -> QuickTerminalConfiguration {
        let config = loadConfig()
        return QuickTerminalConfiguration(
            position: config.quickTerminalPosition.flatMap(QuickTerminalPosition.init(rawValue:)) ?? fallback.position,
            screenFraction: CGFloat(config.quickTerminalScreenFraction ?? Double(fallback.screenFraction)),
            animationDuration: config.quickTerminalAnimationDuration ?? fallback.animationDuration
        )
    }
}
