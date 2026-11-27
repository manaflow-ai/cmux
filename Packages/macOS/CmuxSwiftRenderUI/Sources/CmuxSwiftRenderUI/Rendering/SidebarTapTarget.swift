import CmuxSwiftRender
import SwiftUI

/// A tappable region reported by the rendered sidebar tree: the global frame
/// (root coordinate space, top-left origin) of a `Button` or tap-gesture node
/// and the ``ButtonAction`` it fires.
///
/// Collected via ``SidebarTapTargetsKey`` so an out-of-process render host can
/// hit-test forwarded clicks geometrically instead of synthesizing AppKit
/// events (SwiftUI control gestures don't fire in a never-on-screen window).
public struct SidebarTapTarget: Equatable, Sendable {
    /// The region's frame in the root (`.global`) coordinate space.
    public let frame: CGRect
    /// The action a tap inside ``frame`` fires.
    public let action: ButtonAction

    /// Creates a tap target.
    ///
    /// - Parameters:
    ///   - frame: The region's frame in the root coordinate space.
    ///   - action: The action a tap inside the frame fires.
    public init(frame: CGRect, action: ButtonAction) {
        self.frame = frame
        self.action = action
    }
}

extension View {
    /// Reports this view's global frame as a tappable region firing `action`.
    /// No-op when `action` is `nil`.
    @ViewBuilder
    func reportTapTarget(_ action: ButtonAction?) -> some View {
        if let action {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarTapTargetsKey.self,
                        value: [SidebarTapTarget(frame: proxy.frame(in: .global), action: action)]
                    )
                }
            )
        } else {
            self
        }
    }
}
