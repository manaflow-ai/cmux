public import Foundation

/// One operation in the workspace-scoped floating Dock control domain.
public enum ControlWorkspaceFloatingDockAction: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
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
