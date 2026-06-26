import SwiftUI

extension Image {
    func cmuxFlatSymbolColorRendering() -> Image {
        // `symbolColorRenderingMode(.flat)` is not available in the current SDK
        // used by CI/local builds. Keep this modifier as a compatibility no-op.
        self
    }
}
