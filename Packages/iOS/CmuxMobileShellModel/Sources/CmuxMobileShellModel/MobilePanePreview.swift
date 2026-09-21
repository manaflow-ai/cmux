import Foundation

/// A pane in a Mac workspace, projected into normalized workspace coordinates.
/// The normalized frame lets the task composer render a faithful miniature
/// layout without knowing the Mac window's pixel dimensions.
public struct MobilePanePreview: Identifiable, Equatable, Sendable {
    /// Stable Mac-local pane identifier.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }
    }

    /// A pane rectangle in the workspace's normalized coordinate space.
    public struct Frame: Equatable, Codable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let id: ID
    public let frame: Frame
    public let surfaceIDs: [MobileSurfacePreview.ID]
    public let selectedSurfaceID: MobileSurfacePreview.ID?
    public let isFocused: Bool

    public init(
        id: ID,
        frame: Frame,
        surfaceIDs: [MobileSurfacePreview.ID] = [],
        selectedSurfaceID: MobileSurfacePreview.ID? = nil,
        isFocused: Bool = false
    ) {
        self.id = id
        self.frame = frame
        self.surfaceIDs = surfaceIDs
        self.selectedSurfaceID = selectedSurfaceID
        self.isFocused = isFocused
    }
}
