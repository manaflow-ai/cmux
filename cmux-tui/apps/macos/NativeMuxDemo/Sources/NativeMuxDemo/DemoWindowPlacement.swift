import AppKit
import Foundation

struct SideBySideWindowLayout: Equatable, Sendable {
  let nativeFrame: CGRect
  let ghosttyPositionX: Int
  let ghosttyPositionY: Int
  let ghosttyColumns: Int
  let ghosttyRows: Int

  static func fit(visibleFrame: CGRect) -> SideBySideWindowLayout {
    let gap = min(12.0, max(0, visibleFrame.width * 0.01))
    let availableWidth = max(1, visibleFrame.width - gap)
    let nativeWidth = floor(availableWidth * 0.58)
    let ghosttyWidth = max(1, availableWidth - nativeWidth)
    let nativeFrame = CGRect(
      x: visibleFrame.minX,
      y: visibleFrame.minY,
      width: nativeWidth,
      height: visibleFrame.height
    )

    return SideBySideWindowLayout(
      nativeFrame: nativeFrame,
      ghosttyPositionX: Int(nativeWidth + gap),
      ghosttyPositionY: 0,
      ghosttyColumns: max(60, Int((ghosttyWidth - 24) / 8.2)),
      ghosttyRows: max(20, Int((visibleFrame.height - 58) / 16.5))
    )
  }
}

private struct GhosttyWindowPlacement: Codable {
  let x: Int
  let y: Int
  let columns: Int
  let rows: Int
}

@MainActor
enum DemoWindowPlacement {
  static func applyIfConfigured(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard
      let layoutPath = environment["CMUX_NATIVE_WINDOW_LAYOUT_FILE"],
      !layoutPath.isEmpty,
      let screen = NSScreen.screens.first,
      let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    else { return }

    let layout = SideBySideWindowLayout.fit(visibleFrame: screen.visibleFrame)
    window.setFrame(layout.nativeFrame, display: true)

    let placement = GhosttyWindowPlacement(
      x: layout.ghosttyPositionX,
      y: layout.ghosttyPositionY,
      columns: layout.ghosttyColumns,
      rows: layout.ghosttyRows
    )
    guard let data = try? JSONEncoder().encode(placement) else { return }
    try? data.write(to: URL(fileURLWithPath: layoutPath), options: .atomic)
  }
}
