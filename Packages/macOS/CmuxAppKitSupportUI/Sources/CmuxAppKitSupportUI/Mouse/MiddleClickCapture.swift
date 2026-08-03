/// Native middle-click capture view.
public typealias MiddleClickCapture = MiddleClickCaptureView

public extension MiddleClickCaptureView {
    /// Creates a transparent overlay that intercepts only middle clicks.
    convenience init(onMiddleClick: @escaping () -> Void) {
        self.init(frame: .zero)
        self.onMiddleClick = onMiddleClick
    }
}
