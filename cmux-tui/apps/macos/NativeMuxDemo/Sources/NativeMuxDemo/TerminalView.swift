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
  @Bindable var terminal: NativeTerminalModel

  var body: some View {
    ZStack {
      GhosttySurfaceRepresentable(surfaceView: terminal.surfaceView)
      if !terminal.isAttached, terminal.errorMessage.isEmpty {
        ProgressView(L10n.text("terminal.connecting", "Attaching terminal…"))
          .controlSize(.small)
          .padding(12)
          .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
      if terminal.didExit {
        VStack {
          Spacer()
          Text(L10n.text("terminal.exited", "Process exited"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: .capsule)
            .padding(10)
        }
      }
      if !terminal.errorMessage.isEmpty {
        Text(terminal.errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(10)
          .background(.regularMaterial, in: .rect(cornerRadius: 8))
      }
    }
    .background(Color(nsColor: .black))
  }
}
