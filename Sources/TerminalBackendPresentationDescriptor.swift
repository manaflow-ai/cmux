import CmuxTerminal
import CmuxTerminalRenderProtocol
import Foundation

/// Current app-owned endpoint and visual state for one renderer presentation.
struct TerminalBackendPresentationDescriptor: Equatable, Sendable {
    let presentationID: UUID
    let endpoint: TerminalRenderFrameEndpoint
    let viewport: TerminalExternalViewport
    let focused: Bool
    let visible: Bool
    let preedit: TerminalExternalPreedit?
    let pixelFormat: TerminalRenderPixelFormat
    let colorSpace: TerminalRenderColorSpace
    let resolvedConfigRevision: UInt64
    let resolvedConfig: Data
}
