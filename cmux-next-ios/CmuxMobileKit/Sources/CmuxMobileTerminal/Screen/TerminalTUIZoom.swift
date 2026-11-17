#if os(iOS)
import CmuxMobileLinkFFI
import UIKit

/// The alternate screen's scaled projection (docs/design
/// ios-terminal-projection.md, option C): a full-screen app at the Mac's
/// exact grid, shown at a zoom over it. Pinch zooms about the fingers and
/// snaps to fit width and to readable (the reader's font size); a double tap
/// goes from one to the other about the tap; one finger pans and never
/// reaches the app. The decisions are Rust's (`cmux_terminal_projection::zoom`
/// through `terminalZoom*`); this holds the state and the gestures, and the
/// page applies it as a transform (``TerminalViewController/applyTUIPlacement()``):
/// a zoom or a pan is one frame and sends nothing to the Mac.
@MainActor
final class TerminalTUIZoom: NSObject, @MainActor UIGestureRecognizerDelegate {
    /// The zoom chrome (gallery variants; `-CmuxMobileTerminalZoomChrome`).
    enum Chrome: String, CaseIterable {
        /// Nothing over the grid.
        case none
        /// Column numbers along the top while pinching.
        case ruler
        /// A strip at the bottom trailing corner: the whole grid and the part
        /// on screen, while zooming or panning (the default: it says where
        /// you are in a grid larger than the page, then gets out of the way,
        /// as a scroll indicator does).
        case minimap

        static var current: Chrome {
            UserDefaults.standard.string(forKey: "CmuxMobileTerminalZoomChrome").flatMap(Chrome.init(rawValue:)) ?? .minimap
        }
    }

    /// The zoom applies: a full-screen app whose grid is not the phone's.
    var isActive: () -> Bool = { false }
    /// The Mac's grid and the page, at scale 1 (nil: not laid out).
    var geometry: () -> TerminalZoomGeometry? = { nil }
    /// The grid's columns (the ruler's labels).
    var columns: () -> Int = { 0 }
    /// Places the surface for ``state``.
    var apply: () -> Void = {}
    /// A pinch or a double tap landed (the demo's counter).
    var zoomed: () -> Void = {}

    /// The zoom and pan now.
    private(set) var state = TerminalZoomState(scale: 1, panX: 0, panY: 0)
    /// The zoom rests on fit width: a new page size fits again.
    private var atFitWidth = true
    private var laidOut: TerminalZoomGeometry?
    private var pinchStart: TerminalZoomState?
    private var panStart: TerminalZoomState?
    let chrome = Chrome.current

    private(set) lazy var pinch: UIPinchGestureRecognizer = {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        return pinch
    }()

    private(set) lazy var doubleTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        tap.numberOfTapsRequired = 2
        tap.delegate = self
        return tap
    }()

    private weak var host: UIView?
    /// The TUI host: the grid's page (focus points are in it).
    private weak var page: UIView?
    /// The single tap that waits for a double tap only while the zoom is active.
    private weak var singleTap: UITapGestureRecognizer?
    private let ruler = TerminalZoomRuler()
    private let minimap = TerminalZoomMinimap()
    private var chromeHide: Task<Void, Never>?

    /// `host`: the TUI clip (the gestures' view, the chrome's parent); `page`: the TUI host in it.
    func install(in host: UIView, page: UIView, singleTap: UITapGestureRecognizer) {
        self.page = page
        self.host = host
        self.singleTap = singleTap
        host.addGestureRecognizer(pinch)
        host.addGestureRecognizer(doubleTap)
        for view in [ruler, minimap] as [UIView] {
            view.isHidden = true
            view.isUserInteractionEnabled = false
            host.addSubview(view)
        }
    }

    /// The zoom for the page now: a new grid or page keeps the zoom (fit
    /// width stays fit width), clamped into it. Returns the state to apply.
    func sync() -> TerminalZoomState {
        guard isActive(), let geometry = geometry() else {
            laidOut = nil
            hideChrome(now: true)
            return TerminalZoomState(scale: 1, panX: 0, panY: 0)
        }
        if geometry != laidOut {
            let first = laidOut == nil
            laidOut = geometry
            state = first || atFitWidth ? terminalZoomInitial(grid: geometry) : terminalZoomClamp(grid: geometry, zoom: state)
            if first { atFitWidth = true }
        }
        return state
    }

    /// The app left (or entered) the alternate screen: the next one opens at fit width.
    func reset() {
        laidOut = nil
        atFitWidth = true
        pinchStart = nil
        panStart = nil
        hideChrome(now: true)
    }

    /// One finger: pans the zoomed grid (from the gesture's start).
    func pan(translation: CGPoint, began: Bool) {
        guard let geometry = laidOut else { return }
        if began || panStart == nil { panStart = state }
        guard let start = panStart else { return }
        state = terminalZoomClamp(grid: geometry, zoom: TerminalZoomState(scale: start.scale, panX: start.panX - translation.x,
                                                                           panY: start.panY - translation.y))
        apply()
        showChrome(pinching: false)
    }

    func panEnded() {
        panStart = nil
        scheduleHide()
    }

    /// Typing follows the cursor: the least pan that shows `cell` (surface points at scale 1).
    func reveal(_ cell: CGRect, margin: CGFloat) {
        guard let geometry = laidOut else { return }
        let next = terminalZoomReveal(grid: geometry, zoom: state, x: cell.minX, y: cell.minY, width: cell.width, height: cell.height,
                                      margin: margin)
        guard next != state else { return }
        state = next
        apply()
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let geometry = laidOut, let page else { return }
        let focus = pinch.location(in: page)
        switch pinch.state {
        case .began:
            pinchStart = state
            showChrome(pinching: true)
        case .changed:
            guard let start = pinchStart else { return }
            state = terminalZoomAbout(grid: geometry, zoom: start, scale: start.scale * pinch.scale, focusX: focus.x,
                                      focusY: focus.y)
            apply()
            showChrome(pinching: true)
        case .ended, .cancelled:
            state = terminalZoomSnap(grid: geometry, zoom: state, focusX: focus.x, focusY: focus.y)
            atFitWidth = abs(state.scale - terminalZoomFitWidthScale(grid: geometry)) < 1e-6
            pinchStart = nil
            apply()
            zoomed()
            scheduleHide()
        default:
            break
        }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        guard let geometry = laidOut, let page else { return }
        let at = tap.location(in: page)
        state = terminalZoomToggle(grid: geometry, zoom: state, focusX: at.x, focusY: at.y)
        atFitWidth = abs(state.scale - terminalZoomFitWidthScale(grid: geometry)) < 1e-6
        apply()
        zoomed()
        showChrome(pinching: false)
        scheduleHide()
    }


    // MARK: Gesture delegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive() && laidOut != nil
    }

    /// The single tap waits for a second one only while zooming is possible
    /// (fitted or on the primary screen it is never delayed).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === doubleTap && other === singleTap && isActive()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The pinch and the one-finger pan hand over without lifting.
        gestureRecognizer === pinch && other is UIPanGestureRecognizer
    }

    // MARK: Chrome

    /// Lays the chrome out for the state (the page calls it with each placement).
    func layoutChrome() {
        guard let page, let geometry = laidOut, chrome != .none else { return }
        let area = page.frame
        switch chrome {
        case .none:
            break
        case .ruler:
            ruler.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: 14)
            ruler.update(columns: columns(), scale: state.scale, panX: state.panX, gridWidth: geometry.gridWidth)
        case .minimap:
            let width: CGFloat = 64
            let height = max(12, min(48, width * CGFloat(geometry.gridHeight) / max(1, CGFloat(geometry.gridWidth))))
            minimap.frame = CGRect(x: area.maxX - width - 4,
                                   y: area.maxY - height - 6, width: width, height: height)
            minimap.update(geometry: geometry, state: state)
        }
    }

    private func showChrome(pinching: Bool) {
        chromeHide?.cancel()
        switch chrome {
        case .none:
            return
        case .ruler:
            guard pinching else { return }
            ruler.isHidden = false
            ruler.alpha = 1
        case .minimap:
            // Only when there is somewhere to go.
            guard let geometry = laidOut,
                  geometry.gridWidth * state.scale > geometry.pageWidth + 0.5 || geometry.gridHeight * state.scale > geometry.pageHeight + 0.5
            else { return hideChrome(now: true) }
            minimap.isHidden = false
            minimap.alpha = 1
        }
        layoutChrome()
    }

    private func scheduleHide() {
        chromeHide?.cancel()
        chromeHide = Task { @MainActor [weak self] in
            try? await ContinuousClock().sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.hideChrome(now: false)
        }
    }

    private func hideChrome(now: Bool) {
        chromeHide?.cancel()
        for view in [ruler, minimap] as [UIView] where !view.isHidden {
            if now || UIAccessibility.isReduceMotionEnabled {
                view.isHidden = true
            } else {
                UIView.animate(withDuration: 0.25, animations: { view.alpha = 0 }, completion: { done in if done { view.isHidden = true } })
            }
        }
    }
}

/// The ruler variant: column numbers every ten columns along the grid's top.
final class TerminalZoomRuler: UIView {
    private let ticks = CAShapeLayer()
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.72)
        ticks.strokeColor = UIColor.secondaryLabel.cgColor
        ticks.lineWidth = 0.5
        layer.addSublayer(ticks)
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func update(columns: Int, scale: Double, panX: Double, gridWidth: Double) {
        guard columns > 0 else { return }
        let cell = gridWidth / Double(columns) * scale
        let path = UIBezierPath()
        var shown = 0
        let step = cell * 10 < 28 ? 20 : 10
        for column in stride(from: 0, through: columns, by: step) {
            let x = CGFloat(Double(column) * cell - panX)
            guard x >= -1, x <= bounds.width + 1 else { continue }
            path.move(to: CGPoint(x: x, y: bounds.height - 4))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            let label: UILabel
            if shown < labels.count {
                label = labels[shown]
            } else {
                label = UILabel()
                label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
                label.textColor = .secondaryLabel
                addSubview(label)
                labels.append(label)
            }
            label.isHidden = false
            label.text = "\(column)"
            label.sizeToFit()
            label.frame.origin = CGPoint(x: x + 2, y: 0)
            shown += 1
        }
        for label in labels.dropFirst(shown) { label.isHidden = true }
        ticks.path = path.cgPath
    }
}

/// The minimap variant: the whole grid as an outline and the part on screen filled.
final class TerminalZoomMinimap: UIView {
    private let viewport = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
        layer.borderColor = UIColor.secondaryLabel.cgColor
        layer.borderWidth = 0.5
        layer.cornerRadius = 3
        layer.cornerCurve = .continuous
        viewport.backgroundColor = UIColor.label.withAlphaComponent(0.35)
        viewport.layer.cornerRadius = 1.5
        addSubview(viewport)
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func update(geometry: TerminalZoomGeometry, state: TerminalZoomState) {
        let scaledWidth = max(1, geometry.gridWidth * state.scale)
        let scaledHeight = max(1, geometry.gridHeight * state.scale)
        let x = state.panX / scaledWidth
        let y = state.panY / scaledHeight
        let w = min(1, geometry.pageWidth / scaledWidth)
        let h = min(1, geometry.pageHeight / scaledHeight)
        viewport.frame = CGRect(x: CGFloat(x) * bounds.width, y: CGFloat(y) * bounds.height,
                                width: max(3, CGFloat(w) * bounds.width), height: max(3, CGFloat(h) * bounds.height))
    }
}
#endif
