public import Foundation

public nonisolated struct LaunchRecordWindowSnapshot: Sendable {
    public var id: String
    public var frame: CGRect
    public var displayID: UInt32
    public var backgroundRGBA: (UInt8, UInt8, UInt8, UInt8)
    public var barRGBA: (UInt8, UInt8, UInt8, UInt8)
    public var imagePath: String
    public var imagePixelSize: (width: UInt32, height: UInt32)
    public var workspaceID: String
    public var tabIDs: [String]

    public init(id: String, frame: CGRect, displayID: UInt32 = 0, backgroundRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255),
                barRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255), imagePath: String = "", imagePixelSize: (UInt32, UInt32) = (0, 0),
                workspaceID: String = "", tabIDs: [String] = []) {
        self.id = id; self.frame = frame; self.displayID = displayID
        self.backgroundRGBA = backgroundRGBA; self.barRGBA = barRGBA; self.imagePath = imagePath
        self.imagePixelSize = imagePixelSize; self.workspaceID = workspaceID; self.tabIDs = tabIDs
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
