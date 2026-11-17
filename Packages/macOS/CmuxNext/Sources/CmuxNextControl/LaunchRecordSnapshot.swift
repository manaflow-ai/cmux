public import Foundation

public nonisolated struct LaunchRecordWindowSnapshot: Sendable {
    public var id: String
    public var frame: CGRect
    public var displayID: UInt32
    public var backgroundRGBA: (UInt8, UInt8, UInt8, UInt8)
    public var barRGBA: (UInt8, UInt8, UInt8, UInt8)
    /// The window image's key in the launch image directory, `<build>/<window_id>/<generation>`
    /// (launch record v2, cmux-launch-record); empty when no image is published.
    public var imageKey: String
    public var imagePixelSize: (width: UInt32, height: UInt32)
    public var workspaceID: String
    public var tabIDs: [String]
    /// The window's backing scale (record v2); 0 reads as a v1 record, whose image is always stale.
    public var backingScale: Double
    /// The window's display frame (`NSScreen.frame`, record v2): the stage-0 window draws the image only
    /// on a display with this frame and scale.
    public var screenFrame: CGRect
    /// The chrome is dark (record v2 `appearance` 1), else light (0).
    public var appearanceDark: Bool
    /// The window's theme is a light/dark pair: its image is stale after the system appearance flips.
    public var appearanceFollowsSystem: Bool
    public var fullscreen: Bool

    public init(id: String, frame: CGRect, displayID: UInt32 = 0, backgroundRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255),
                barRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255), imageKey: String = "", imagePixelSize: (UInt32, UInt32) = (0, 0),
                workspaceID: String = "", tabIDs: [String] = [], backingScale: Double = 0, screenFrame: CGRect = .zero,
                appearanceDark: Bool = false, appearanceFollowsSystem: Bool = false, fullscreen: Bool = false) {
        self.id = id; self.frame = frame; self.displayID = displayID
        self.backgroundRGBA = backgroundRGBA; self.barRGBA = barRGBA; self.imageKey = imageKey
        self.imagePixelSize = imagePixelSize; self.workspaceID = workspaceID; self.tabIDs = tabIDs
        self.backingScale = backingScale; self.screenFrame = screenFrame; self.appearanceDark = appearanceDark
        self.appearanceFollowsSystem = appearanceFollowsSystem; self.fullscreen = fullscreen
    }
}

public nonisolated struct LaunchRecordSidebarSnapshot: Sendable {
    public var id: String, title: String, iconKey: String
    public init(id: String, title: String, iconKey: String) { self.id = id; self.title = title; self.iconKey = iconKey }
}

public nonisolated struct LaunchRecordSnapshot: Sendable {
    public var windows: [LaunchRecordWindowSnapshot]
    public var sidebarRows: [LaunchRecordSidebarSnapshot]
    public var sessionSocketPath: String
    public init(windows: [LaunchRecordWindowSnapshot] = [], sidebarRows: [LaunchRecordSidebarSnapshot] = [], sessionSocketPath: String = "") {
        self.windows = windows; self.sidebarRows = sidebarRows; self.sessionSocketPath = sessionSocketPath
    }
}
