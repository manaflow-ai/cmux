import SwiftUI

#if os(iOS) && DEBUG
/// Zero-impact store-side composer seam for UI tests (DEBUG only).
///
/// Carries the composer source-of-truth store flags as a stable, parseable
/// `accessibilityValue` (`isComposerPresented=…;composerFocusRequest=…;draftLength=…`)
/// on an element identified by `MobileComposerStoreProbe`, so a UI test can assert the
/// store and the surface's mirror (`MobileComposerDockProbe`) agree across repeated
/// open/close cycles and that the draft survives. Rendered as a 1×1 clear element so it
/// never perturbs layout or intercepts touches. Never compiled into a shipping build.
struct ComposerStoreProbe: View {
    let isComposerPresented: Bool
    let composerFocusRequest: Int
    let draftLength: Int

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("MobileComposerStoreProbe")
            .accessibilityValue(
                [
                    "isComposerPresented=\(isComposerPresented ? 1 : 0)",
                    "composerFocusRequest=\(composerFocusRequest)",
                    "draftLength=\(draftLength)",
                ].joined(separator: ";")
            )
    }
}
#endif
