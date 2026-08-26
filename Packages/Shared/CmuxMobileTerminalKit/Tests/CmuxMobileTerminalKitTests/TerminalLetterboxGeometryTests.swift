import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalLetterboxGeometry pixel math")
struct TerminalLetterboxGeometryTests {
    @Test("container pixel size floors point*scale")
    func containerPixels() {
        let px = TerminalLetterboxGeometry.containerPixelSize(
            container: CGSize(width: 402, height: 400),
            scale: 3
        )
        #expect(px.width == 1206)
        #expect(px.height == 1200)

        // Fractional point sizes floor, not round.
        let frac = TerminalLetterboxGeometry.containerPixelSize(
            container: CGSize(width: 100.9, height: 50.4),
            scale: 2
        )
        #expect(frac.width == 201) // floor(201.8)
        #expect(frac.height == 100) // floor(100.8)
    }

    @Test("grid request pixel size floors cols*cellWidth")
    func gridRequest() {
        let px = TerminalLetterboxGeometry.gridRequestPixelSize(
            cols: 80,
            rows: 24,
            cellPixelSize: CGSize(width: 9.6, height: 20.0)
        )
        #expect(px.width == 768) // floor(80 * 9.6 = 768.0)
        #expect(px.height == 480) // 24 * 20
    }

    @Test("cell pixel size divides measured extent by grid counts")
    func cellPixels() {
        let cell = TerminalLetterboxGeometry.cellPixelSize(
            columns: 80, rows: 24, widthPx: 768, heightPx: 480
        )
        #expect(cell == CGSize(width: 9.6, height: 20.0))
    }

    @Test("cell pixel size is zero when any dimension is non-positive")
    func cellPixelsZero() {
        #expect(TerminalLetterboxGeometry.cellPixelSize(columns: 0, rows: 24, widthPx: 768, heightPx: 480) == .zero)
        #expect(TerminalLetterboxGeometry.cellPixelSize(columns: 80, rows: 24, widthPx: 0, heightPx: 480) == .zero)
    }

    @Test("no pin when effective grid fills the natural grid")
    func noPinWhenFills() {
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 100, rows: 40),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    @Test("no pin when effective grid is within one cell of natural")
    func noPinWithinOneCell() {
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 99, rows: 39),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    @Test("pins to a smaller effective grid producing a point-size box")
    func pinsSmallerGrid() {
        // effective 60x30, natural 100x40, cell 9x18 px at scale 3.
        // pinnedW = 60 * 9 / 3 = 180, pinnedH = 30 * 18 / 3 = 180.
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 60, rows: 30),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == CGSize(width: 180, height: 180))
    }

    @Test("no pin when the pinned box is not meaningfully smaller than the container")
    func noPinWhenNotSmaller() {
        // pinnedW = 134*9/3 = 402 == container width, pinnedH = 233*18/3 ≈ 1398 > container.
        // Both axes fail the (pinned + 0.5 < container) test on width and natural
        // fills, so confirm a near-equal box does not pin.
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 134, rows: 116),
            measuredColumns: 134,
            measuredRows: 116,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    // MARK: - Keyboard open/closed full-height contract

    // iPhone 16-ish portrait: 402x874 bounds, 34pt home indicator, 44pt toolbar.
    private static let phoneBounds = CGSize(width: 402, height: 874)
    private static let homeIndicator: CGFloat = 34
    private static let toolbar: CGFloat = 44
    private static let keyboard: CGFloat = 336

    @Test("bare container: full bounds minus only the safe area (no composer/toolbar)")
    func fullHeightBare() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            composerBandHeight: 0,
            toolbarHeight: 0,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        #expect(size.width == 402)
        #expect(size.height == 840) // 874 - 34
    }

    @Test("chrome visible: reserves safe area + toolbar + composer band")
    func fullHeightWithChrome() {
        let composer: CGFloat = 120
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            composerBandHeight: composer,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        // 874 - (34 safe area + 44 toolbar + 120 composer) = 676.
        #expect(size.height == 676)
    }

    // The keyboard is not a parameter of `terminalContainerSize` AT ALL: the
    // grid keeps its keyboard-down size while the keyboard is up and the host
    // slides the full-height render so its bottom edge rides the composer
    // bar. The signature is the regression guard — a keyboard-driven resize
    // cannot come back without re-adding the parameter.

    @Test("chrome hidden: terminal reclaims toolbar, composer AND the bottom safe area")
    func chromeHiddenReclaimsEverything() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            composerBandHeight: 120,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: true
        )
        // HIDE button: nothing reserved, grid is the entire bounds.
        #expect(size.height == 874)
    }

    @Test("keyboard occupancy uses keyboard when up, safe area when down")
    func keyboardOccupancyContract() {
        #expect(TerminalLetterboxGeometry.keyboardOccupancy(keyboardHeight: 336, bottomSafeAreaInset: 34) == 336)
        #expect(TerminalLetterboxGeometry.keyboardOccupancy(keyboardHeight: 0, bottomSafeAreaInset: 34) == 34)
        // Defensive: a negative inset cannot grow the reservation.
        #expect(TerminalLetterboxGeometry.keyboardOccupancy(keyboardHeight: 0, bottomSafeAreaInset: -10) == 0)
    }

    @Test("resolved safe-area inset distrusts a stale-zero view inset")
    func resolvedSafeAreaPrefersWindowWhenViewIsZero() {
        // Right after the keyboard hides, the view's own safeAreaInsets.bottom
        // can lag at 0 for a layout pass while the window already reports the
        // home indicator. Trusting the view inset would briefly under-reserve
        // and let the grid extend under the home indicator, then snap back. The
        // resolver must take the window value instead.
        #expect(TerminalLetterboxGeometry.resolvedBottomSafeAreaInset(viewInset: 0, windowInset: 34) == 34)
        // When the view inset is present it wins (it is the most specific).
        #expect(TerminalLetterboxGeometry.resolvedBottomSafeAreaInset(viewInset: 34, windowInset: 34) == 34)
        // Both zero (pre-window-attach) => 0.
        #expect(TerminalLetterboxGeometry.resolvedBottomSafeAreaInset(viewInset: 0, windowInset: 0) == 0)
    }

    @Test("keyboard absorption slack: blank rows absorb before content moves")
    func keyboardAbsorptionSlackContract() {
        // Post-`clear` shell: nearly the whole render is blank, so the whole
        // intrusion is absorbed and the terminal stays top-pinned.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: 700, intrusion: 302
        ) == 302)
        // Full screen of content: nothing to absorb, plain bottom-pin.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: 0, intrusion: 302
        ) == 0)
        // Partially filled: content slides only past the blank rows, so the
        // transition from top-pin to bottom-pin is continuous.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: 120, intrusion: 302
        ) == 120)
        // Unknown content bottom (or alternate screen): safe bottom-pin.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: nil, intrusion: 302
        ) == 0)
        // Keyboard down: no intrusion, no slack, natural layout.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: 700, intrusion: 0
        ) == 0)
        // Defensive: negative inputs cannot create motion.
        #expect(TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: -5, intrusion: -5
        ) == 0)
    }

    @Test("clampPinnedSize bounds refined pixels by the container")
    func clampPinned() {
        // refined 540x540 px at scale 3 = 180x180 points, within container.
        let within = TerminalLetterboxGeometry.clampPinnedSize(
            actualWidthPx: 540, actualHeightPx: 540, scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(within == CGSize(width: 180, height: 180))

        // refined exceeds container -> clamped.
        let clamped = TerminalLetterboxGeometry.clampPinnedSize(
            actualWidthPx: 3000, actualHeightPx: 3000, scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(clamped == CGSize(width: 402, height: 700))
    }
}
