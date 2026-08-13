#if os(iOS)
import CmuxMobileSupport
import Foundation

/// The five experimental Feed compositions. The data and interaction model is
/// shared by every composition; this value only selects its visual grammar.
enum AgentFeedVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case orbit
    case signal
    case commandDeck
    case prism
    case pulse

    var id: String { rawValue }

    var title: String {
        L10n.string(localizationKey, defaultValue: defaultTitle)
    }

    var subtitle: String {
        L10n.string(subtitleLocalizationKey, defaultValue: defaultSubtitle)
    }

    var symbolName: String {
        switch self {
        case .orbit: "circle.dotted"
        case .signal: "dot.radiowaves.left.and.right"
        case .commandDeck: "rectangle.3.group"
        case .prism: "diamond"
        case .pulse: "waveform.path.ecg"
        }
    }

    var localizationKey: StaticString {
        switch self {
        case .orbit: "mobile.feed.variant.orbit"
        case .signal: "mobile.feed.variant.signal"
        case .commandDeck: "mobile.feed.variant.commandDeck"
        case .prism: "mobile.feed.variant.prism"
        case .pulse: "mobile.feed.variant.pulse"
        }
    }

    var subtitleLocalizationKey: StaticString {
        switch self {
        case .orbit: "mobile.feed.variant.orbit.subtitle"
        case .signal: "mobile.feed.variant.signal.subtitle"
        case .commandDeck: "mobile.feed.variant.commandDeck.subtitle"
        case .prism: "mobile.feed.variant.prism.subtitle"
        case .pulse: "mobile.feed.variant.pulse.subtitle"
        }
    }

    private var defaultTitle: String.LocalizationValue {
        switch self {
        case .orbit: "Orbit"
        case .signal: "Signal"
        case .commandDeck: "Command Deck"
        case .prism: "Prism"
        case .pulse: "Pulse"
        }
    }

    private var defaultSubtitle: String.LocalizationValue {
        switch self {
        case .orbit: "A calm constellation of every agent turn."
        case .signal: "A live radio board for attention and motion."
        case .commandDeck: "Dense, keyboard-minded operator cards."
        case .prism: "Layered glass for code, context, and action."
        case .pulse: "A compact timeline that keeps work moving."
        }
    }
}
#endif
