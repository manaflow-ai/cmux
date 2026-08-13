import CMUXMobileCore
import CmuxMobileTerminal
import Foundation

@MainActor
final class TerminalSurfaceDelegate: GhosttySurfaceViewDelegate {
    var didResize: ((TerminalGridSize) -> Void)?
    var didUpdateScrollBoundary: ((TerminalScrollBoundary) -> Void)?
    var didPresentLocalScrollbackViewportRow: ((UInt64) -> Void)?

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didProduceInput data: Data
    ) {}

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didResize size: TerminalGridSize,
        reportID: UInt64
    ) {
        didResize?(size)
    }

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didUpdateScrollBoundary boundary: TerminalScrollBoundary
    ) {
        didUpdateScrollBoundary?(boundary)
    }

    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didPresentLocalScrollbackViewportRow row: UInt64
    ) {
        didPresentLocalScrollbackViewportRow?(row)
    }
}
