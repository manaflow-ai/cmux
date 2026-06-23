public import CMUXMobileCore
public import Foundation

/// Terminal output payload delivered to a mounted mobile terminal surface.
public enum MobileTerminalOutputPayload: Equatable, Sendable {
    /// Raw VT bytes for fallback compatibility.
    case bytes(Data)
    /// Semantic render-grid state that should stay typed until the renderer.
    case renderGrid(MobileTerminalRenderGridEnvelope)
}
