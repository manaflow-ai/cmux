import AppKit
import Observation

/// Window-local layout state shared only by the native trailing accessory and its sidebar spacer.
@MainActor
@Observable
final class TitlebarTrailingControlsLayoutState {
    private(set) var reservationWidth: CGFloat = 0

    func setReservationWidth(_ rawWidth: CGFloat) {
        let width = rawWidth.isFinite ? max(0, rawWidth) : 0
        guard abs(width - reservationWidth) > 0.5 else { return }
        reservationWidth = width
    }
}
