import AppKit

/// `ZStack`: its children layered in order (the last on top), each centered in the stack. The stack
/// is as wide as its widest child (it fills when one fills) and as high as its highest.
final class AppSceneZStackNSView: AppSceneNodeNSView {
    override var contentNaturalWidth: CGFloat? {
        var widest: CGFloat = 0
        for child in childViews {
            guard let width = child.naturalWidth else { return nil }
            widest = max(widest, width)
        }
        return widest
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        childViews.map { $0.height(width: min($0.naturalWidth ?? width, width)) }.max() ?? 0
    }

    override func layoutContent(in rect: CGRect) {
        for child in childViews {
            let width = min(child.naturalWidth ?? rect.width, rect.width)
            let height = child.height(width: width)
            child.frame = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height).integral
        }
    }
}
