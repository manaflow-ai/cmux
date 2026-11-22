/// One pane the picture stands in for: its id and where it was in the window's content view (top-left points).
public nonisolated struct RelaunchCoverSurface: Codable, Sendable, Equatable {
    public var id: String
    public var rect: RelaunchCoverRect

    public init(id: String, rect: RelaunchCoverRect) {
        self.id = id
        self.rect = rect
    }
}

public nonisolated struct RelaunchCoverWindow: Codable, Sendable, Equatable {
    public var id: String
    public var frame: RelaunchCoverRect
    public var screenFrame: RelaunchCoverRect
    public var scale: Double
    /// 0 is frontmost.
    public var order: UInt32
    public var key: Bool
    public var fullscreen: Bool
    /// The picture's file name in the folder (`<id>.png`).
    public var image: String
    public var surfaces: [RelaunchCoverSurface]

    public init(id: String, frame: RelaunchCoverRect, screenFrame: RelaunchCoverRect, scale: Double, order: UInt32, key: Bool,
                fullscreen: Bool, image: String, surfaces: [RelaunchCoverSurface]) {
        self.id = id; self.frame = frame; self.screenFrame = screenFrame; self.scale = scale; self.order = order
        self.key = key; self.fullscreen = fullscreen; self.image = image; self.surfaces = surfaces
    }
}

public nonisolated struct RelaunchCoverManifest: Codable, Sendable, Equatable {
    public var version: UInt32 = 1
    public var cause: RelaunchCoverCause
    public var writtenAtMs: UInt64
    public var build: String
    public var windows: [RelaunchCoverWindow]

    public init(cause: RelaunchCoverCause, writtenAtMs: UInt64, build: String, windows: [RelaunchCoverWindow]) {
        self.cause = cause; self.writtenAtMs = writtenAtMs; self.build = build; self.windows = windows
    }
}
