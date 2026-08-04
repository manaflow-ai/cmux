#if os(iOS)
import UIKit

final class TranscriptCollectionView: UICollectionView, UIGestureRecognizerDelegate {
    #if DEBUG
    private weak var touchDebugDot: UIView?
    #endif

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UITEST_CHROME_DEBUG"] == "1" {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleDebugTouch(_:)))
            recognizer.minimumPressDuration = 0
            recognizer.allowableMovement = .greatestFiniteMagnitude
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        #endif
    }

    required init?(coder: NSCoder) {
        nil
    }
    #if DEBUG
    var allowsReloadData = true
    private(set) var reloadDataCallCount = 0
    private(set) var cellAnimationDuringScrollCount = 0
    #endif

    override func layoutSubviews() {
        let suppressesLayoutAnimation = isTracking || isDragging || isDecelerating
        if suppressesLayoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        super.layoutSubviews()
        if suppressesLayoutAnimation {
            CATransaction.commit()
        }
        #if DEBUG
        if suppressesLayoutAnimation {
            let animatedCells = visibleCells.filter { cell in
                !(cell.layer.animationKeys() ?? []).isEmpty
                    || !(cell.contentView.layer.animationKeys() ?? []).isEmpty
            }
            if !animatedCells.isEmpty {
                cellAnimationDuringScrollCount += animatedCells.count
                assertionFailure("Transcript cells must not have implicit layer animations during active scrolling")
            }
        } else {
            assertRestingRhythmTokens()
        }
        #endif
    }

    override func reloadData() {
        #if DEBUG
        reloadDataCallCount += 1
        if !allowsReloadData {
            assertionFailure("TranscriptListViewController must not call reloadData after initial mount")
        }
        #endif
        super.reloadData()
    }

    func updateAccessibilityOrder() {
        let coordinateView = superview ?? self
        accessibilityElements = visibleCells.sorted { lhs, rhs in
            lhs.convert(lhs.bounds, to: coordinateView).minY < rhs.convert(rhs.bounds, to: coordinateView).minY
        }
    }

    #if DEBUG
    @objc private func handleDebugTouch(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let window else { return }
        touchDebugDot?.removeFromSuperview()
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        dot.center = recognizer.location(in: window)
        dot.backgroundColor = .systemPink
        dot.layer.cornerRadius = 8
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 2
        dot.isUserInteractionEnabled = false
        dot.accessibilityIdentifier = "transcript.chrome.touch-down"
        window.addSubview(dot)
        touchDebugDot = dot
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
    #endif

    #if DEBUG
    func assertRestingRhythmTokens() {
        guard !isTracking, !isDragging, !isDecelerating else { return }
        let visibleBounds = bounds.insetBy(dx: 0, dy: -0.5)
        let cells = visibleCells.compactMap { $0 as? TranscriptCollectionCell }
            .filter { $0.frame.intersects(visibleBounds) }
            .sorted { $0.frame.minY < $1.frame.minY }
        for pair in zip(cells, cells.dropFirst()) {
            let geometricGap = pair.1.frame.minY - pair.0.frame.maxY
            assert(
                abs(geometricGap) < 0.5,
                "Transcript cells must remain contiguous (gap: \(geometricGap), frames: \(pair.0.frame), \(pair.1.frame))"
            )
            guard let olderRow = pair.0.row, let newerRow = pair.1.row else { continue }
            let visualGap = pair.0.rowSpacing.bottom + pair.1.rowSpacing.top
            let activeDensity = pair.0.rowSpacing.density
            assert(pair.1.rowSpacing.density == activeDensity)
            let expected = TranscriptRowSpacing.gap(
                betweenNewer: newerRow,
                older: olderRow,
                density: activeDensity
            )
            assert(abs(expected - visualGap) < 0.5, "Transcript row gap must equal its adjacent-kind rhythm token")
        }
    }
    #endif
}
#endif
