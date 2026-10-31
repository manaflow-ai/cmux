import Foundation
import Observation

/// One window's right sidebar: whether it shows, which section and how wide.
/// The last choice is remembered in `defaults` for the next window and launch.
/// It starts minimal: hidden, and narrow when it first shows.
@MainActor
@Observable
final class RightSidebarModel {
    /// The sidebar's width on a first show, before any drag.
    static let width: CGFloat = 260
    /// The widths a drag can reach.
    static let widthRange: ClosedRange<CGFloat> = 200...560
    static let widthKey = "rightSidebar.width"
    static let visibleKey = "rightSidebar.visible"
    static let modeKey = "rightSidebar.mode"

    private(set) var isVisible: Bool {
        didSet { if isVisible != oldValue { defaults.set(isVisible, forKey: Self.visibleKey) } }
    }
    private(set) var mode: RightSidebarMode {
        didSet { if mode != oldValue { defaults.set(mode.rawValue, forKey: Self.modeKey) } }
    }
    /// The sidebar's width while it shows, inside ``widthRange``.
    private(set) var width: CGFloat
    // UserDefaults is documented thread-safe; it is only read and written here.
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: Where the choice persists (tests pass a suite of their own).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        isVisible = defaults.bool(forKey: Self.visibleKey)
        mode = defaults.string(forKey: Self.modeKey).flatMap(RightSidebarMode.init(rawValue:)) ?? .sessions
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? Self.clamped(stored) : Self.width
    }

    /// Sets the width live during a drag, kept inside ``widthRange``; ``saveWidth()`` remembers it.
    func resize(to proposed: CGFloat) { width = Self.clamped(proposed) }

    /// Remembers the width for the next window and launch (a drag's end).
    func saveWidth() { defaults.set(Double(width), forKey: Self.widthKey) }

    private static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Shows the sidebar, at `mode` when given.
    func show(_ mode: RightSidebarMode? = nil) {
        if let mode { self.mode = mode }
        isVisible = true
    }

    func hide() { isVisible = false }
}
