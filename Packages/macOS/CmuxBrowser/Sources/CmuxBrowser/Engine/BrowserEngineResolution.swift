import Foundation

/// The outcome of resolving the engine for a new browser panel.
public enum BrowserEngineResolution: Equatable, Hashable, Sendable {
    /// Open the panel with this choice.
    case open(BrowserEngineChoice)
    /// Do not open the panel: an explicitly requested engine is unavailable.
    case refuse(BrowserEngineKind, BrowserEngineUnavailableReason)
}
