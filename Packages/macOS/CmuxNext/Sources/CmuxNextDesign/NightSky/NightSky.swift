public import SwiftUI

/// SwiftUI host for ``NightSkyView``, Sleepy Mode's sky.
///
/// ```swift
/// NightSky(loops: Motion.panes.animatesLoops).ignoresSafeArea()
/// ```
public struct NightSky: NSViewRepresentable {
    /// Whether the stars twinkle and the Zs rise (``NightSkyView/loops``).
    public var loops: Bool

    /// - Parameter loops: Whether the loops run; false shows the still sky.
    public init(loops: Bool) {
        self.loops = loops
    }

    public func makeNSView(context: Context) -> NightSkyView {
        let view = NightSkyView(frame: .zero)
        view.loops = loops
        return view
    }

    public func updateNSView(_ view: NightSkyView, context: Context) {
        view.loops = loops
    }
}
