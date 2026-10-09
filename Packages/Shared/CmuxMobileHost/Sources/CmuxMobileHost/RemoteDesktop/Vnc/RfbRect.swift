public import Foundation

/// One rectangle of a FramebufferUpdate, decoded.
public struct RfbRect: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// `width * height * 4` bytes of BGRA.
        case raw(Data)
        case copy(sourceX: Int, sourceY: Int)
        /// DesktopSize pseudo-encoding: the framebuffer is now `width x height`.
        case desktopSize
    }

    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var content: Content

    public init(x: Int, y: Int, width: Int, height: Int, content: Content) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.content = content
    }
}
