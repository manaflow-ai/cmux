import Foundation

/// Event-only actions used by layout views below collection boundaries.
@MainActor
struct LayoutActions {
  let focusPane: (String) -> Void
  let splitPane: (String, String) -> Void
  let createNiriColumn: (String) -> Void
  let zoomPane: (String, Bool) -> Void
  let createTerminalTab: (String) -> Void
  let createBrowserTab: (String) -> Void
  let closePane: (String) -> Void
  let setViewportWidth: (String, Int) -> Void
  let setSplitRatio: (String, String, Double) -> Void
  let focusTab: (TabSnapshot) -> Void
  let closeTab: (TabSnapshot) -> Void

  init(model: FrontendModel) {
    focusPane = { model.focusPane($0) }
    splitPane = { model.splitPane($0, direction: $1) }
    createNiriColumn = { model.createNiriColumn(after: $0) }
    zoomPane = { model.zoomPane($0, enabled: $1) }
    createTerminalTab = { model.createTerminalTab(in: $0) }
    createBrowserTab = { model.createBrowserTab(in: $0) }
    closePane = { model.closePane($0) }
    setViewportWidth = { model.setViewportWidth(paneID: $0, columns: $1) }
    setSplitRatio = { model.setSplitRatio(paneID: $0, splitID: $1, ratio: $2) }
    focusTab = { model.focusTab($0) }
    closeTab = { model.closeTab($0) }
  }
}
