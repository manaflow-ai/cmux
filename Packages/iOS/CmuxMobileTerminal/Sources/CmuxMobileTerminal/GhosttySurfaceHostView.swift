#if canImport(UIKit)
import UIKit

/// Plain UIKit root that owns the terminal's keyboard guide and bottom dock.
///
/// `GhosttySurfaceView` is an aggressively relaid-out `CAMetalLayer` renderer. Keeping
/// the keyboard constraint on this separate, layout-passive root prevents renderer
/// geometry updates from committing an interrupted keyboard transition's model frame.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView

    public init(surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: surfaceView.frame)

        backgroundColor = surfaceView.backgroundColor
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        surfaceView.moveBottomDock(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
