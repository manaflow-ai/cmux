import AppKit
import CmuxNextDesign

/// Screen views: the animated screen switch.
extension LayoutRootView {
    func switchScreens(from old: ScreenID?, to new: ScreenID?, order: [ScreenID], animated: Bool) -> Bool {
        let oldIndex = old.flatMap { order.firstIndex(of: $0) } ?? -1
        let newIndex = new.flatMap { order.firstIndex(of: $0) } ?? 0
        let direction: CGFloat = newIndex >= oldIndex ? 1 : -1
        let shift = bounds.width * 0.18
        for (id, view) in screenViews {
            guard var frame = screenFrames[id] else { continue }
            if id == new {
                if view.isHidden || frame.alpha.value < 0.01 {
                    frame = AnimatedFrame(bounds.offsetBy(dx: direction * shift, dy: 0), alpha: 0)
                }
                view.isHidden = false
                frame.setTarget(bounds, alpha: 1)
            } else if id == old {
                frame.setTarget(bounds.offsetBy(dx: -direction * shift, dy: 0), alpha: 0)
            } else {
                frame.setTarget(bounds, alpha: 0)
                frame.snap()
            }
            if !animated { frame.snap() }
            screenFrames[id] = frame
        }
        applyScreenFrames()
        return animated
    }

    func applyScreenFrames() {
        for (id, frame) in screenFrames {
            guard let view = screenViews[id] else { continue }
            view.setFrameOrigin(frame.rect.origin)
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            view.alphaValue = frame.alpha.value
            if id != model.activeScreenID && frame.alpha.value <= 0.001 && frame.alpha.target == 0 {
                view.isHidden = true
            }
        }
    }
}
