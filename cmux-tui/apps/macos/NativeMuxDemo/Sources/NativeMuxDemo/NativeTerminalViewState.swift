import Foundation

/// Immutable terminal presentation state passed through SwiftUI collection subtrees.
@MainActor
struct NativeTerminalViewState {
  let surfaceView: GhosttyRemoteSurfaceView
  let errorMessage: String
  let isAttached: Bool
  let didExit: Bool
}
