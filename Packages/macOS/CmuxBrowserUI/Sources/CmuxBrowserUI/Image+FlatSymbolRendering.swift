public import SwiftUI

extension Image {
    /// Compatibility no-op for flat symbol color rendering.
    ///
    /// `symbolColorRenderingMode(.flat)` is not available in the current SDK
    /// used by CI/local builds. Keep this modifier as a compatibility no-op so
    /// call sites can adopt it without an availability gate.
    public func cmuxFlatSymbolColorRendering() -> Image {
        self
    }
}
