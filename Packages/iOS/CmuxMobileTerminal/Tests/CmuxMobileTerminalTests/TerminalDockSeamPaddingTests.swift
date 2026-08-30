#if canImport(UIKit)
import CmuxMobileTerminalKit
import CoreGraphics
import Testing

/// The bottom-pinned terminal render must not sit flush against the composer
/// bar: while the chrome is visible the grid container reserves a small seam
/// above the dock so the last row of content keeps clear air over the
/// toolbar. With the chrome hidden there is no bar to keep clear of, so the
/// grid still reclaims the full bounds.
struct TerminalDockSeamPaddingTests {
    // iPhone 16-ish portrait: 402x874 bounds, 34pt home indicator, 44pt
    // toolbar, 120pt open composer band.
    private static let phoneBounds = CGSize(width: 402, height: 874)

    @Test("chrome-visible container reserves a seam above the composer bar")
    func chromeVisibleReservesSeam() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            composerBandHeight: 120,
            toolbarHeight: 44,
            bottomSafeAreaInset: 34,
            chromeHidden: false
        )
        // 874 - (34 safe area + 44 toolbar + 120 composer + 8 seam) = 668.
        #expect(size.height == 668)
    }

    @Test("chrome hidden reclaims the full bounds — no seam without a bar")
    func chromeHiddenHasNoSeam() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            composerBandHeight: 120,
            toolbarHeight: 44,
            bottomSafeAreaInset: 34,
            chromeHidden: true
        )
        #expect(size.height == 874)
    }
}
#endif
