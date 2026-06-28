public import SwiftUI

extension Image {
    /// Compatibility no-op standing in for `symbolColorRenderingMode(.flat)`,
    /// which is unavailable in the current SDK used by CI/local builds.
    public func cmuxFlatSymbolColorRendering() -> Image {
        // `symbolColorRenderingMode(.flat)` is not available in the current SDK
        // used by CI/local builds. Keep this modifier as a compatibility no-op.
        self
    }
}
