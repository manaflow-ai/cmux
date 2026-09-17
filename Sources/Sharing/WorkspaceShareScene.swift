import Foundation

struct WorkspaceShareScene: Encodable, Sendable {
    struct Frame: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Surface: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable {
            case terminal
            case browser
            case textbox
            case unsupported
        }

        let id: String
        let title: String
        let kind: Kind
        let docId: String?
        let imageDataUrl: String?
    }

    struct Pane: Encodable, Sendable {
        let id: String
        let frame: Frame
        let selectedSurfaceId: String
        let surfaces: [Surface]
    }

    let workspaceId: String
    let workspaceTitle: String
    let layoutRevision: UInt64
    let width: Double
    let height: Double
    let panes: [Pane]
}
