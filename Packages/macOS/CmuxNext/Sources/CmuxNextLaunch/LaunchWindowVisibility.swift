public import CmuxNextDesign
public import CoreGraphics

/// Which restored windows behind the front one show at launch: visibility is by
/// occlusion and display, not by z-order. A window shows when it is on the active Space, on a
/// connected display, and no window in front of it covers it, judged from the saved frames before
/// any of them is built.
///
/// The cover test is the one the live windows use (``WindowOcclusionRule``, a copy of Chrome's
/// `WebContentsOcclusionCheckerMac -isWindowOccluded:`,
/// content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm): one window in front whose
/// frame contains the window's frame covers it, with no region union. Chrome's session restore
/// likewise loads the tabs that show first and the rest later (chrome/browser/sessions/session_restore.cc,
/// `TabLoader`).
///
/// ```swift
/// let visibility = LaunchWindowVisibility(screens: NSScreen.screens.map(\.frame), rule: WindowOcclusionRule(appHidden: NSApp.isHidden))
/// let split = visibility.split(savedFrontToBack, built: ["front"])
/// // split.visible: build after the first frame; split.hidden: build after startup
/// ```
public nonisolated struct LaunchWindowVisibility: Sendable {
    /// One saved window, as the launch places it.
    public struct Saved: Sendable, Equatable {
        public let id: String
        /// Its frame in screen coordinates after placement; nil when it has none (it opens centered).
        public let frame: CGRect?
        /// False for a window that opens on a Space of its own (one saved in full screen).
        public let onActiveSpace: Bool

        public init(id: String, frame: CGRect?, onActiveSpace: Bool = true) {
            self.id = id
            self.frame = frame
            self.onActiveSpace = onActiveSpace
        }
    }

    /// The windows to build, in front-to-back order.
    public struct Split: Sendable, Equatable {
        /// Windows that show: each builds in its own post after the first frame.
        public var visible: [String]
        /// Covered, off-screen or on another Space: each builds after startup, or when something acts in it.
        public var hidden: [String]

        public init(visible: [String] = [], hidden: [String] = []) {
            self.visible = visible
            self.hidden = hidden
        }
    }

    /// The frames of the connected displays.
    public let screens: [CGRect]
    /// The cover test, with the app's hidden and display-sleep state.
    public let rule: WindowOcclusionRule

    public init(screens: [CGRect], rule: WindowOcclusionRule = WindowOcclusionRule()) {
        self.screens = screens
        self.rule = rule
    }

    /// Splits the windows of `frontToBack` not in `built` into the ones that show and the hidden ones.
    ///
    /// - Parameters:
    ///   - frontToBack: The launch's open windows, front first, the built ones too (they cover the others).
    ///   - built: Windows already built or building now: they are judged by no list.
    /// - Returns: The others, each in one list, in front-to-back order.
    public func split(_ frontToBack: [Saved], built: Set<String>) -> Split {
        // The rule tells windows apart by object identity; a saved window has no NSWindow yet.
        let marks = frontToBack.map { _ in WindowMark() }
        let facts = zip(frontToBack, marks).compactMap { saved, mark in
            saved.frame.map { WindowOcclusionFacts(id: ObjectIdentifier(mark), frame: $0, systemVisible: saved.onActiveSpace) }
        }
        var split = Split()
        for (saved, mark) in zip(frontToBack, marks) where !built.contains(saved.id) {
            if shows(saved, id: ObjectIdentifier(mark), among: facts) {
                split.visible.append(saved.id)
            } else {
                split.hidden.append(saved.id)
            }
        }
        return split
    }

    private func shows(_ saved: Saved, id: ObjectIdentifier, among facts: [WindowOcclusionFacts]) -> Bool {
        guard saved.onActiveSpace, !rule.appHidden, !rule.displaysAsleep else { return false }
        // No saved frame: it opens centered on the main display, over nothing in particular.
        guard let frame = saved.frame else { return !screens.isEmpty }
        guard screens.contains(where: { $0.intersects(frame) }), let fact = facts.first(where: { $0.id == id }) else { return false }
        return !rule.isOccluded(fact, frontToBack: facts)
    }
}

/// A saved window's identity in ``WindowOcclusionFacts``.
private final class WindowMark: Sendable {}
