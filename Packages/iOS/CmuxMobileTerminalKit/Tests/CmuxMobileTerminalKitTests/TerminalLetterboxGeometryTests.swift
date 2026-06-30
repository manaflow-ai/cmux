import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalLetterboxGeometry pixel math")
struct TerminalLetterboxGeometryTests {
    @Test("drawable container subtracts keyboard overlap and floors at 1")
    func drawableContainer() {
        let full = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 0
        )
        #expect(full == CGSize(width: 402, height: 700))

        let withKeyboard = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 300
        )
        #expect(withKeyboard == CGSize(width: 402, height: 400))
    }

    @Test("keyboard taller than bounds is clamped so height stays >= 1")
    func keyboardClamp() {
        let clamped = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 5000
        )
        // bottomInset clamps to height-1 = 699, container height = 700-699 = 1.
        #expect(clamped == CGSize(width: 402, height: 1))
    }

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

    @Test("keyboard DOWN: terminal fills full bounds minus only the safe area (no composer/toolbar)")
    func fullHeightKeyboardDownBare() {
        // The bare contract the user reports: keyboard closed => full height
        // minus only the bottom safe area. Toolbar/composer reservations are
        // tested separately so this isolates the keyboard-open/closed axis.
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0,
            composerBandHeight: 0,
            toolbarHeight: 0,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        #expect(size.width == 402)
        #expect(size.height == 840) // 874 - 34
    }

    @Test("keyboard DOWN with chrome: reserves safe area + toolbar + composer band")
    func fullHeightKeyboardDownWithChrome() {
        let composer: CGFloat = 120
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0,
            composerBandHeight: composer,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        // 874 - (34 safe area + 44 toolbar + 120 composer) = 676.
        #expect(size.height == 676)
    }

    @Test("keyboard UP: terminal is reduced by the keyboard height, not also the safe area")
    func reducedHeightKeyboardUp() {
        let composer: CGFloat = 120
        let down = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0,
            composerBandHeight: composer,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        let up = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: Self.keyboard,
            composerBandHeight: composer,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        // Keyboard up: the keyboard covers the home indicator, so occupancy is
        // the keyboard height ALONE (not keyboard + safe area). The grid loses
        // exactly (keyboard - safe area) more than the keyboard-down case.
        #expect(up.height == 874 - (Self.keyboard + Self.toolbar + composer))
        #expect(down.height - up.height == Self.keyboard - Self.homeIndicator)
        // And it is meaningfully shorter than keyboard-down.
        #expect(up.height < down.height)
    }

    @Test("keyboard-down height does NOT depend on a stale prior keyboard value")
    func keyboardDownHeightIgnoresStaleKeyboard() {
        // Simulate the up->down transition: once keyboardHeight returns to 0 the
        // height must be the full keyboard-down height, regardless of how tall
        // the keyboard was a frame ago. The function takes the CURRENT keyboard
        // height only, so a stale value cannot leak in.
        let afterHide = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0, // settled down
            composerBandHeight: 0,
            toolbarHeight: 0,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        let neverShown = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0,
            composerBandHeight: 0,
            toolbarHeight: 0,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: false
        )
        #expect(afterHide == neverShown)
        #expect(afterHide.height == 840) // 874 - 34
    }

    @Test("chrome hidden: terminal reclaims toolbar, composer AND the bottom safe area")
    func chromeHiddenReclaimsEverything() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: 0,
            composerBandHeight: 120,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: true
        )
        // HIDE button: nothing reserved (no keyboard), grid is the entire bounds.
        #expect(size.height == 874)
    }

    @Test("chrome hidden with keyboard still up reserves only the keyboard")
    func chromeHiddenKeyboardUp() {
        let size = TerminalLetterboxGeometry.terminalContainerSize(
            bounds: Self.phoneBounds,
            keyboardHeight: Self.keyboard,
            composerBandHeight: 120,
            toolbarHeight: Self.toolbar,
            bottomSafeAreaInset: Self.homeIndicator,
            chromeHidden: true
        )
        #expect(size.height == 874 - Self.keyboard)
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
