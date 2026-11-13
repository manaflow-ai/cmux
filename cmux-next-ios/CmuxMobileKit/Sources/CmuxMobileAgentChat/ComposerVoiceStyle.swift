/// How the composer's voice button is drawn (CMUX-39). One filled circle per composer:
/// alone (no draft) the voice button is the primary control and keeps its
/// filled circle; beside Stop it is secondary, a plain glyph at the weight of the plus.
/// Voice mode on is always the accent circle, so its state stays visible.
///
/// Plain logic with no UIKit or SwiftUI, outside `#if os(iOS)`, so the macOS `swift test`
/// leg compiles and runs ComposerVoiceStyleTests too. Its color lives with the composer.
struct ComposerVoiceStyle: Equatable {
    let primaryIsVisible: Bool
    let active: Bool

    enum Fill: Equatable { case accent, neutral, plain }

    var isFilled: Bool { active || !primaryIsVisible }

    var fill: Fill {
        if active { return .accent }
        return isFilled ? .neutral : .plain
    }
}
