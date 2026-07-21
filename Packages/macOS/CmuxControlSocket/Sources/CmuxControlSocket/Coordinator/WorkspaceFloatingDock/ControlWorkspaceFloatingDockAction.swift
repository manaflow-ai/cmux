public import Foundation

/// One operation in the workspace-scoped floating Dock control domain.
public enum ControlWorkspaceFloatingDockAction: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        /// A generous upper bound that covers current display walls while
        /// preventing pathological native-window backing allocations.
        public static let maximumDimension = 16_384.0
        /// Window origins beyond this range are not useful display coordinates
        /// and can overflow AppKit geometry internals.
        public static let maximumCoordinateMagnitude = 1_000_000.0

        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public static func isWithinSupportedBounds(
            x: Double,
            y: Double,
            width: Double,
            height: Double
        ) -> Bool {
            x.isFinite
                && y.isFinite
                && width.isFinite
                && height.isFinite
                && abs(x) <= maximumCoordinateMagnitude
                && abs(y) <= maximumCoordinateMagnitude
                && width > 0
                && height > 0
                && width <= maximumDimension
                && height <= maximumDimension
        }
    }

    case list
    case create(
        title: String?,
        frame: Frame?,
        kind: String,
        url: String?,
        backgroundTintHex: String?,
        relativeToSelector: String?,
        focus: Bool
    )
    case setPresented(selector: String, presented: Bool, focus: Bool)
    case focus(selector: String)
    case close(selector: String)
    case closeAll
    case setFrame(selector: String, frame: Frame)
    case colorGet(selector: String)
    case colorSet(selector: String, backgroundTintHex: String?)
    case noteGet(selector: String)
    case noteSet(selector: String, text: String)
    case surfaceCreate(selector: String, paneID: UUID?, kind: String, url: String?, focus: Bool)
    case paneCreate(
        selector: String,
        sourceSurfaceID: UUID?,
        kind: String,
        direction: String,
        url: String?,
        focus: Bool
    )
}
