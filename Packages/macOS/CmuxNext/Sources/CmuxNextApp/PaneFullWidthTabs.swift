import CmuxNextBridge
import CmuxNextBridgeUI
import Foundation
import Observation

/// The panes in Full Width Tab mode (`palette.toggleFullWidthTab`, classic #7425): such a pane's
/// tab strip shows only its selected tab, across the whole strip. A pane's own view choice, kept
/// per pane key in `defaults` like Hide Tab Bar (``PaneTabBarChoices``), so it survives a relaunch.
@Observable
final class PaneFullWidthTabs {
    /// The panes remembered, newest last; older choices are dropped.
    static let maximumPanes = 512
    private static let defaultsKey = "panes.fullWidthTab"
    @ObservationIgnored private let defaults: UserDefaults
    private var panes: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<String>()
        panes = (defaults.stringArray(forKey: Self.defaultsKey) ?? []).filter { seen.insert($0).inserted }
    }

    /// Whether pane `paneKey` shows its selected tab full width.
    func contains(_ paneKey: String) -> Bool { panes.contains(paneKey) }

    /// Turns pane `paneKey`'s mode over and returns the new mode.
    @discardableResult
    func toggle(_ paneKey: String) -> Bool {
        let on = !contains(paneKey)
        panes.removeAll { $0 == paneKey }
        if on { panes.append(paneKey) }
        if panes.count > Self.maximumPanes { panes.removeFirst(panes.count - Self.maximumPanes) }
        defaults.set(panes, forKey: Self.defaultsKey)
        return on
    }
}

extension PaneController {
    /// Full Width Tab on this pane: tab `id` is selected first (classic focused it), so turning
    /// the mode on shows the tab the action was run on.
    func toggleFullWidthTab(showing id: StripTabID) {
        if stripModel.selectedID != id, stripModel.tab(id) != nil { select(id) }
        services.paneFullWidthTabs.toggle(paneKey)
        apply(snapshot())
    }
}
