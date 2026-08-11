import AppKit
import SwiftUI

private struct GhosttySurfaceRepresentable: NSViewRepresentable {
  let surfaceView: GhosttyRemoteSurfaceView

  func makeNSView(context: Context) -> GhosttyRemoteSurfaceView {
    surfaceView
  }

  func updateNSView(_ view: GhosttyRemoteSurfaceView, context: Context) {
    _ = view
    _ = context
  }
}

struct TerminalSurfaceView: View {
  @Environment(\.localization) private var localization
  let state: NativeTerminalViewState

  var body: some View {
    ZStack {
      GhosttySurfaceRepresentable(surfaceView: state.surfaceView)
      if !state.isAttached, state.errorMessage.isEmpty {
        ProgressView(localization.text("terminal.connecting", "Attaching terminal…"))
          .controlSize(.small)
          .padding(12)
          .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
      if state.didExit {
        VStack {
          Spacer()
          Text(localization.text("terminal.exited", "Process exited"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: .capsule)
            .padding(10)
        }
      }
      if !state.errorMessage.isEmpty {
        VStack(spacing: 8) {
          Text(state.errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
          if let retryAttach = state.retryAttach {
            Button(localization.text("terminal.retry_attach", "Retry"), action: retryAttach)
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
          }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
    }
    .background(Color(nsColor: .black))
  }
}
