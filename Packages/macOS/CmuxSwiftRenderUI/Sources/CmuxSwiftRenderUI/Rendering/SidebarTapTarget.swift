public import CoreGraphics
import CmuxSwiftRender

/// A tappable region in the rendered sidebar's root coordinate space.
public struct SidebarTapTarget: Equatable, Sendable {
    public let frame: CGRect
    public let action: ButtonAction

    public init(frame: CGRect, action: ButtonAction) {
        self.frame = frame
        self.action = action
    }
}

@MainActor
protocol SidebarTapTargetProviding: AnyObject {
    var sidebarTapAction: ButtonAction? { get }
}
