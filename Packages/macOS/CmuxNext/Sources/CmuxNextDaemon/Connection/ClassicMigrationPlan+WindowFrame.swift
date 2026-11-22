public import Foundation

extension ClassicMigrationPlan.Window {
    /// The saved frame when one of `visibleFrames` (each screen's `NSScreen.visibleFrame`) shows most of it: at least
    /// 200 points of its width, or all of a narrower one. Otherwise nil, and the window opens at the default place.
    ///
    /// - Parameter visibleFrames: The screens' visible frames now.
    /// - Returns: ``frame`` when it is on a screen, else nil.
    public func frame(onScreens visibleFrames: [CGRect]) -> CGRect? {
        guard let frame else { return nil }
        return visibleFrames.contains { $0.intersection(frame).width >= min(200, frame.width) } ? frame : nil
    }
}
