import Foundation
import Observation

/// One window's right sidebar: whether it shows and which section. The last
/// choice is remembered in `defaults` for the next window and launch.
@MainActor
@Observable
final class RightSidebarModel {
    /// The sidebar's width while it shows.
    static let width: CGFloat = 300
    static let visibleKey = "rightSidebar.visible"
    static let modeKey = "rightSidebar.mode"

    private(set) var isVisible: Bool {
        didSet { if isVisible != oldValue { defaults.set(isVisible, forKey: Self.visibleKey) } }
    }
    private(set) var mode: RightSidebarMode {
        didSet { if mode != oldValue { defaults.set(mode.rawValue, forKey: Self.modeKey) } }
    }
    // UserDefaults is documented thread-safe; it is only read and written here.
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: Where the choice persists (tests pass a suite of their own).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibleKey)
        mode = defaults.string(forKey: Self.modeKey).flatMap(RightSidebarMode.init(rawValue:)) ?? .sessions
    }

    /// Shows the sidebar, at `mode` when given.
    func show(_ mode: RightSidebarMode? = nil) {
        if let mode { self.mode = mode }
        isVisible = true
    }

    func hide() { isVisible = false }
}
