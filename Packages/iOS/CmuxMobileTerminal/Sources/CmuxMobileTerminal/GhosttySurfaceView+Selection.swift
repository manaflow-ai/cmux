#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import GhosttyKit
import OSLog
import UIKit

nonisolated private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface")

/// One-finger / trackpad text selection, the glyph-aligned highlight overlay, the
/// local grid-text copy, and the "Copied N characters" HUD — the drag-to-select
/// feature lifted out of ``GhosttySurfaceView`` so the view file is not the home
/// for this whole subsystem. The pure cell↔rect math lives in
/// `TerminalSelectionGeometry.swift`; the recognizers, overlay, anchor, and toast
/// views remain stored on ``GhosttySurfaceView`` (Swift keeps stored properties on
/// the main declaration), and only the access level of the members this extension
/// touches was widened from `private` to `internal`. The view's PUBLIC surface is
/// unchanged.
extension GhosttySurfaceView {
    /// Apply the one-finger-selects preference to the live recognizers. When on,
    /// a single finger drives text selection and the scroll view needs two
    /// fingers to pan; when off, the scroll view reverts to one-finger scrolling
    /// (the original behavior) and the selection drag is disabled.
    func applyGesturePreference() {
        if gesturePreference.oneFingerSelects {
            scrollMechanicsView.panGestureRecognizer.minimumNumberOfTouches = 2
            selectionPanRecognizer?.isEnabled = true
        } else {
            scrollMechanicsView.panGestureRecognizer.minimumNumberOfTouches = 1
            selectionPanRecognizer?.isEnabled = false
        }
    }

    /// `NotificationCenter` selector for ``MobileTerminalGesturePreference/didChangeNotification``:
    /// re-applies the live recognizer configuration so a Settings toggle takes
    /// effect without relaunching.
    @objc func handleGesturePreferenceChanged() {
        applyGesturePreference()
    }

    /// One-finger (and trackpad / indirect-pointer) drag → a self-owned text
    /// selection highlight, independent of ghostty's selection and the inbound
    /// render-grid stream.
    ///
    /// The iPad terminal is a thin mirror: the Mac owns ghostty's selection and
    /// re-streams already-highlighted cells, so driving the LOCAL surface's
    /// selection (the old `ghostty_surface_mouse_*` path) was invisible — the
    /// Mac never heard it and the next inbound frame repainted over it. Instead
    /// the drag tracks an anchor cell at touch-down and a focus cell under the
    /// finger, paints the selected rects into ``selectionOverlay`` (layered above
    /// the Metal surface), and on release extracts the text from the local grid
    /// mirror via `ghostty_surface_read_text` and copies it to the pasteboard.
    ///
    /// The double/triple-tap word/line path (``handleTap`` → `didTapAtCol` → Mac
    /// round-trip) is unaffected; only the drag is local.
    @objc func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
        let kind = recognizer === selectionPointerPanRecognizer ? "pointer" : "touch"
        guard let surface else {
            log.notice("selectPan ignored kind=\(kind, privacy: .public) reason=no-surface state=\(recognizer.state.rawValue, privacy: .public)")
            return
        }
        guard let geometry = selectionGeometry(for: surface) else {
            log.notice("selectPan ignored kind=\(kind, privacy: .public) reason=no-geometry state=\(recognizer.state.rawValue, privacy: .public)")
            return
        }
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            // A `UIPanGestureRecognizer` only reaches `.began` AFTER the touch
            // crosses the ~10pt pan slop, so `point` is already past the true
            // touch-down. Recover the down-point from the recognizer's cumulative
            // translation so the anchor cell is the cell the finger actually
            // started on (the same recovery taps rely on for the start cell).
            let translation = recognizer.translation(in: self)
            let startPoint = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            let anchor = gridCell(at: startPoint)
            let focus = gridCell(at: point)
            selectionAnchorCell = anchor
            ensureSelectionOverlay().setColor(selectionHighlightColor.cgColor)
            renderSelectionOverlay(anchor: anchor, focus: focus, geometry: geometry)
            log.notice("selectPan.began kind=\(kind, privacy: .public) anchorCell=(\(anchor.col, privacy: .public),\(anchor.row, privacy: .public)) nowCell=(\(focus.col, privacy: .public),\(focus.row, privacy: .public))")
        case .changed:
            guard let anchor = selectionAnchorCell else { return }
            let focus = gridCell(at: point)
            renderSelectionOverlay(anchor: anchor, focus: focus, geometry: geometry)
        case .ended:
            guard let anchor = selectionAnchorCell else { return }
            let focus = gridCell(at: point)
            renderSelectionOverlay(anchor: anchor, focus: focus, geometry: geometry)
            log.notice("selectPan.ended kind=\(kind, privacy: .public) anchorCell=(\(anchor.col, privacy: .public),\(anchor.row, privacy: .public)) endCell=(\(focus.col, privacy: .public),\(focus.row, privacy: .public))")
            finalizeLocalSelection(anchor: anchor, focus: focus, geometry: geometry, surface: surface)
        case .cancelled, .failed:
            log.notice("selectPan.cancelled kind=\(kind, privacy: .public)")
            clearLocalSelectionOverlay()
        default:
            break
        }
    }

    /// Wrap `scrollCell(at:)` into a ``TerminalGridCell``. Taps use the same
    /// mapping, so the drag anchor lands on the same cell a tap there would.
    private func gridCell(at point: CGPoint) -> TerminalGridCell {
        let cell = scrollCell(at: point)
        return TerminalGridCell(col: cell.col, row: cell.row)
    }

    /// Snapshot the current cell metrics for selection math, using ghostty's OWN
    /// rendering geometry so a cell's rect covers the exact pixels ghostty drew
    /// the glyph into (and `scrollCell(at:)` maps a point inside that rect back
    /// to the same cell):
    ///
    /// - cell size is the TRUE per-cell advance `cell_width_px` / `cell_height_px`
    ///   reported by `ghostty_surface_size`, NOT the legacy `width_px / columns`
    ///   (`width_px` is the full surface incl. padding, so that average folds the
    ///   right-edge remainder into every column and drifts the highlight off the
    ///   glyphs — worse the further right you go);
    /// - origin is `lastRenderRect.origin` plus the `window-padding` glyph inset,
    ///   because ghostty draws the grid inset from the surface edge
    ///   (`col = floor((x − padding.left) / cell_width)`, `renderer/size.zig`).
    ///
    /// `nil` until the first layout has measured a non-empty render rect and a
    /// real cell size.
    func selectionGeometry(for surface: ghostty_surface_t) -> TerminalSelectionCellGeometry? {
        guard !lastRenderRect.isEmpty, cellPixelSize.width > 0, cellPixelSize.height > 0 else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0 else { return nil }
        let scale = max(preferredScreenScale, 1)
        let inset = Self.gridGlyphInsetPoints(scale: scale)
        return TerminalSelectionCellGeometry(
            origin: CGPoint(
                x: lastRenderRect.minX + inset.x,
                y: lastRenderRect.minY + inset.y
            ),
            cellWidth: max(CGFloat(size.cell_width_px) / scale, 1),
            cellHeight: max(CGFloat(size.cell_height_px) / scale, 1),
            columns: Int(size.columns),
            rows: Int(size.rows)
        )
    }

    /// Points the rendered grid's first glyph sits inside `lastRenderRect`.
    /// Ghostty insets the grid by `window-padding-x` / `window-padding-y`, resolved
    /// as `floor(points · scale)` pixels then back to points — the same
    /// `scaledPadding` math `ghostty/src/Surface.zig` runs (iOS font DPI is 72, so
    /// the cell-pixel scale and the screen-point scale are identical).
    ///
    /// The padding points are read from ``GhosttyRuntime/windowPaddingXPoints`` /
    /// ``GhosttyRuntime/windowPaddingYPoints`` — the SAME constants that generate
    /// the iOS ghostty config (`window-padding-x` defaults to 2, `-y` is forced to
    /// 0), so this inset can never drift from what ghostty actually renders.
    /// libghostty's C `ghostty_config_get` cannot return the padding back (its
    /// `WindowPadding` value type is a non-`packed` struct without a `cval`, so
    /// `c_get` returns false), so the config-generating constant is the single
    /// source of truth. Folding the inset into the selection origin keeps the
    /// hit-test and the overlay rects on ghostty's true glyph origin instead of
    /// the bare render-rect corner.
    private static func gridGlyphInsetPoints(scale: CGFloat) -> CGPoint {
        let leftPx = (CGFloat(GhosttyRuntime.windowPaddingXPoints) * scale).rounded(.down)
        let topPx = (CGFloat(GhosttyRuntime.windowPaddingYPoints) * scale).rounded(.down)
        return CGPoint(x: leftPx / scale, y: topPx / scale)
    }

    /// Translucent highlight tint: the terminal's configured `selection-background`
    /// if present, else a system tint. Alpha is forced translucent so the glyphs
    /// under the highlight stay legible.
    private var selectionHighlightColor: UIColor {
        (configSelectionColor ?? .systemBlue).withAlphaComponent(0.35)
    }

    private func ensureSelectionOverlay() -> TerminalSelectionOverlay {
        if let selectionOverlay {
            return selectionOverlay
        }
        let overlay = TerminalSelectionOverlay(color: selectionHighlightColor.cgColor)
        overlay.attach(to: layer)
        selectionOverlay = overlay
        return overlay
    }

    /// Paint the selection rects for the inclusive `anchor…focus` range.
    private func renderSelectionOverlay(
        anchor: TerminalGridCell,
        focus: TerminalGridCell,
        geometry: TerminalSelectionCellGeometry
    ) {
        let rects = geometry.selectionRects(anchor: anchor, focus: focus)
        ensureSelectionOverlay().update(rects: rects, scale: max(preferredScreenScale, 1))
    }

    /// On release: extract the selected text from the local grid mirror and put
    /// it on the system pasteboard. The highlight stays painted (the overlay is
    /// the source of truth) until a tap, scroll, zoom, or new drag clears it.
    private func finalizeLocalSelection(
        anchor: TerminalGridCell,
        focus: TerminalGridCell,
        geometry: TerminalSelectionCellGeometry,
        surface: ghostty_surface_t
    ) {
        let range = geometry.normalizedRange(anchor: anchor, focus: focus)
        guard let text = readLocalGridText(start: range.start, end: range.end, surface: surface),
              !text.isEmpty else {
            // An empty read (e.g. a whitespace-only span ghostty trims away) has
            // nothing to copy.
            log.notice("selectCopy local empty start=(\(range.start.col, privacy: .public),\(range.start.row, privacy: .public)) end=(\(range.end.col, privacy: .public),\(range.end.row, privacy: .public))")
            return
        }
        UIPasteboard.general.string = text
        log.notice("selectCopy local len=\(text.utf8.count, privacy: .public)")

        // Confirm the copy with a transient HUD ("Copied N characters").
        presentCopyToast(characterCount: text.count)
    }

    /// Read the mirrored text for the inclusive viewport cell range. The local
    /// ghostty surface is fed the Mac's PTY bytes via `process_output`, so its
    /// screen buffer holds the same cell contents the Mac shows — a
    /// `GHOSTTY_POINT_VIEWPORT` / `GHOSTTY_POINT_COORD_EXACT` read over the range
    /// returns the selected text (ghostty handles line joins / trailing-space
    /// trimming). Only the on-device *selection* is unreliable, not the content.
    private func readLocalGridText(
        start: TerminalGridCell,
        end: TerminalGridCell,
        surface: ghostty_surface_t
    ) -> String? {
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(max(start.col, 0)),
            y: UInt32(max(start.row, 0))
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(max(end.col, 0)),
            y: UInt32(max(end.row, 0))
        )
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Drop the drag anchor and hide the highlight. Called on a tap, a scroll, a
    /// zoom, and a cancelled drag.
    func clearLocalSelectionOverlay() {
        selectionAnchorCell = nil
        selectionOverlay?.clear()
    }

    /// Present (or refresh) the "Copied N characters" HUD and restart its
    /// quiet-fade window. Mirrors ``showZoomOverlay()``: animate alpha→1 on first
    /// show, stamp `copyToastLastShown`, and let the display link fade it later.
    private func presentCopyToast(characterCount: Int) {
        let overlay = ensureCopyToastOverlay()
        copyToastLabel?.text = String(
            localized: "terminal.copy_toast.copied",
            defaultValue: "Copied \(characterCount) characters"
        )
        layoutCopyToastOverlay()
        copyToastLastShown = CACurrentMediaTime()
        if !copyToastShown {
            copyToastShown = true
            overlay.isHidden = false
            bringSubviewToFront(overlay)
            UIView.animate(withDuration: 0.18) { overlay.alpha = 1 }
        }
    }

    /// Fade the copy toast out (mirrors ``fadeOutZoomOverlay()``). Driven by the
    /// display link once the toast has been quiet for `copyToastVisibleDuration`.
    func fadeOutCopyToast() {
        guard copyToastShown, let overlay = copyToastOverlay else { return }
        copyToastShown = false
        UIView.animate(
            withDuration: 0.3,
            animations: { overlay.alpha = 0 },
            completion: { [weak overlay] _ in
                if overlay?.alpha == 0 { overlay?.isHidden = true }
            }
        )
    }

    /// Lazily build the copy toast: a blur chip wrapping a centered label, styled
    /// to match the zoom HUD's title chip so the two HUDs read as one system.
    private func ensureCopyToastOverlay() -> UIView {
        if let copyToastOverlay { return copyToastOverlay }
        let chip = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        chip.layer.cornerRadius = 9
        chip.layer.cornerCurve = .continuous
        chip.layer.zPosition = 1100
        chip.clipsToBounds = true
        chip.alpha = 0
        chip.isHidden = true
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: chip.contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: chip.contentView.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: chip.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: chip.contentView.trailingAnchor, constant: -14),
        ])
        addSubview(chip)
        copyToastOverlay = chip
        copyToastLabel = label
        return chip
    }

    /// Center the copy toast horizontally and pin it near the top of the area
    /// above the keyboard/toolbar (the zoom HUD owns mid-height at 0.45).
    private func layoutCopyToastOverlay() {
        guard let copyToastOverlay else { return }
        let fitting = copyToastOverlay.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let size = CGSize(width: max(fitting.width, 1), height: max(fitting.height, 1))
        let bottomReserve = composerBandHeight + reservedToolbarHeight + keyboardOccupancyInBounds
        let availableH = max(1, bounds.height - bottomReserve)
        copyToastOverlay.bounds = CGRect(origin: .zero, size: size)
        copyToastOverlay.center = CGPoint(x: bounds.midX, y: availableH * 0.14)
    }
}
#endif
