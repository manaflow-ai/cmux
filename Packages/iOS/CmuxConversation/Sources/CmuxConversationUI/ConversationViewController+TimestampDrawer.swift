#if canImport(UIKit)
import CmuxConversationGeometry
import QuartzCore
import UIKit

/// Swipe left anywhere on the transcript to reveal send times, driven like
/// Messages by the transcript's own scroll pan (see `TimestampDrawerPhysics`):
/// the scroll view's touch slop and vertical scrolling stay native, a drag
/// that starts while the transcript is still moving is caught at once, and
/// the drawer opens only once the finger is clearly moving sideways.
extension ConversationViewController {
    func installTimestampDrawer() {
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(handleTimestampDrawerPan(_:)))
    }

    @objc private func handleTimestampDrawerPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: collectionView)
        switch pan.state {
        case .began:
            stopTimestampDrawerRelease()
            if timestampDrawer.offset == 0 {
                timestampDrawer.maxOffset = MessageCell.timestampRevealDistance()
                timestampDrawer.peekDistance = Self.timestampDrawerPeekDistance
                applyTimestampRevealDistance(timestampDrawer.maxOffset)
            }
            timestampDrawerEnabled = !isSelecting && !touchBelongsToTextSelection(pan.location(in: collectionView))
            timestampDrawer.begin(translation: translation)
            timestampDrawerLastMove = (translation, CACurrentMediaTime())
        case .changed:
            guard timestampDrawerEnabled else { return }
            if translation != timestampDrawerLastMove.translation {
                timestampDrawerLastMove = (translation, CACurrentMediaTime())
            }
            timestampDrawer.update(translation: translation)
            setTimestampReveal(timestampDrawer.fraction)
        case .ended, .cancelled, .failed:
            let stillFor = CACurrentMediaTime() - timestampDrawerLastMove.time
            guard let release = timestampDrawer.end(velocity: pan.velocity(in: collectionView), stillFor: stillFor) else { return }
            startTimestampDrawerRelease(release)
        default:
            break
        }
    }

    /// iOS 27 Messages opens the drawer 20 pt later than iOS 26 under the same drag.
    private static var timestampDrawerPeekDistance: CGFloat {
        if #available(iOS 27, *) { return TimestampDrawerPhysics.iOS27PeekDistance }
        return TimestampDrawerPhysics.chatKitPeekDistance
    }

    private func applyTimestampRevealDistance(_ distance: CGFloat) {
        timestampRevealDistance = distance
        for case let cell as MessageCell in collectionView.visibleCells {
            cell.timestampRevealDistance = distance
        }
    }

    func setTimestampReveal(_ reveal: CGFloat) {
        guard reveal != timestampReveal else { return }
        timestampReveal = reveal
        // Message rows and the typing bubble slide (see
        // `TimestampDrawerRows`); centered rows stay, as in Messages.
        for cell in collectionView.visibleCells {
            if let cell = cell as? MessageCell {
                cell.timestampReveal = reveal
            } else if let cell = cell as? TypingCell {
                cell.timestampDrawerOffset = reveal * timestampRevealDistance
            }
        }
    }

    private func startTimestampDrawerRelease(_ release: TimestampDrawerPhysics.Release) {
        stopTimestampDrawerRelease()
        timestampDrawerRelease = release
        timestampDrawerReleaseStart = nil
        let link = CADisplayLink(target: TimestampDrawerFrameTarget(self), selector: #selector(TimestampDrawerFrameTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        timestampDrawerLink = link
    }

    fileprivate func stepTimestampDrawerRelease(_ link: CADisplayLink) {
        guard link === timestampDrawerLink, let release = timestampDrawerRelease else {
            link.invalidate()
            return
        }
        let start = timestampDrawerReleaseStart ?? link.timestamp
        timestampDrawerReleaseStart = start
        let closed = timestampDrawer.settle(release, elapsed: link.targetTimestamp - start)
        setTimestampReveal(timestampDrawer.fraction)
        if closed { stopTimestampDrawerRelease() }
    }

    private func stopTimestampDrawerRelease() {
        timestampDrawerLink?.invalidate()
        timestampDrawerLink = nil
        timestampDrawerRelease = nil
    }
}

/// Holds the controller weakly so the display link never keeps it alive.
@MainActor
private final class TimestampDrawerFrameTarget: NSObject {
    private weak var controller: ConversationViewController?

    init(_ controller: ConversationViewController) {
        self.controller = controller
    }

    @objc func step(_ link: CADisplayLink) {
        guard let controller else {
            link.invalidate()
            return
        }
        controller.stepTimestampDrawerRelease(link)
    }
}
#endif
