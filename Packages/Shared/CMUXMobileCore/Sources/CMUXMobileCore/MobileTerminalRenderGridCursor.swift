extension MobileTerminalRenderGridFrame.Cursor {
    public enum Location: String, Codable, Equatable, Sendable {
        case viewport
        case aboveViewport = "above_viewport"
        case belowViewport = "below_viewport"
    }

    public enum Style: String, Codable, Equatable, Sendable {
        case block
        case bar
        case underline
        case blockHollow = "block_hollow"
    }
}
