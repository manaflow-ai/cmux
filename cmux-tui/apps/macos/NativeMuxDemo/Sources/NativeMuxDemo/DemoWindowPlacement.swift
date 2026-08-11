import AppKit
import Foundation
import OSLog

struct SideBySideWindowLayout: Equatable, Sendable {
  let nativeFrame: CGRect
  let ghosttyPositionX: Int
  let ghosttyPositionY: Int
  let ghosttyColumns: Int
  let ghosttyRows: Int

  var ghosttyPlacement: GhosttyWindowPlacement {
    GhosttyWindowPlacement(
      x: ghosttyPositionX,
      y: ghosttyPositionY,
      columns: ghosttyColumns,
      rows: ghosttyRows
    )
  }

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

struct GhosttyWindowPlacement: Codable, Equatable, Sendable {
  let x: Int
  let y: Int
  let columns: Int
  let rows: Int
}

@MainActor
protocol DemoWindowPlacementWindow: AnyObject {
  var placementVisibleFrame: CGRect? { get }
  func applyPlacementFrame(_ frame: CGRect)
}

extension NSWindow: DemoWindowPlacementWindow {
  var placementVisibleFrame: CGRect? { screen?.visibleFrame }

  func applyPlacementFrame(_ frame: CGRect) {
    setFrame(frame, display: true)
  }
}

@MainActor
final class DemoWindowPlacement {
  private let windowProvider: () -> (any DemoWindowPlacementWindow)?
  private let writeData: (Data, URL) throws -> Void
  private let logger: Logger

  init(
    windowProvider: @escaping () -> (any DemoWindowPlacementWindow)?,
    writeData: @escaping (Data, URL) throws -> Void,
    logger: Logger = Logger(
      subsystem: "com.cmux.NativeMuxDemo",
      category: "window-placement"
    )
  ) {
    self.windowProvider = windowProvider
    self.writeData = writeData
    self.logger = logger
  }

  func applyIfConfigured(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard
      let layoutPath = environment["CMUX_NATIVE_WINDOW_LAYOUT_FILE"],
      !layoutPath.isEmpty,
      let window = windowProvider(),
      let visibleFrame = window.placementVisibleFrame
    else { return }

    let layout = SideBySideWindowLayout.fit(visibleFrame: visibleFrame)
    window.applyPlacementFrame(layout.nativeFrame)

    let placement = layout.ghosttyPlacement
    do {
      let data = try JSONEncoder().encode(placement)
      try writeData(data, URL(fileURLWithPath: layoutPath))
    } catch {
      logger.error(
        "Failed to write the Ghostty window layout: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
