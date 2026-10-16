import Foundation
import WebKit

/// Immutable destination snapshot captured when presentation measurement begins.
struct WorkspaceSwitchPresentationTarget {
    let workspaceID: UUID
    let contentKind: WorkspaceSwitchContentKind
    let terminalSurfaceID: UUID?
    let terminalView: GhosttyNSView?
    let terminalRendererPresented: Bool
    let terminalRenderedFrameSequence: UInt64
    let browserWebView: WKWebView?
    let portalPresented: Bool
    let interactionReady: Bool
    let requiresInteraction: Bool
}
