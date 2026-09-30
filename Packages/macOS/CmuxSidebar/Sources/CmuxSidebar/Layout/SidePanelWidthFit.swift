public import CoreGraphics

/// Which side panels a main window shows so its terminal area never gets
/// squeezed below ``minimumTerminalWidth``.
///
/// The left sidebar and the right sidebar (files, search, dock and the other
/// modes) each have a minimum width. A window narrower than the panels it
/// shows plus a usable terminal used to compress everything, down to a
/// zero-width terminal. The fix follows `NSSplitViewItem.canCollapseFromWindowResize`:
/// panels that do not fit collapse as the window shrinks, the right one first
/// because it is the secondary panel, and a panel collapsed this way comes
/// back on its own once the window is wide enough again. A panel the person
/// hid stays hidden.
public struct SidePanelWidthFit: Equatable, Sendable {
    /// The narrowest terminal area the window keeps, in points: a prompt and
    /// about 25 columns at the default font. Two full-width panels
    /// (240 + 276) plus this still fit a half-screen window on a 1470 pt
    /// display.
    public static let minimumTerminalWidth: CGFloat = 200

    public enum Panel: Sendable {
        case left
        case right
    }

    public var isLeftVisible: Bool
    public var isRightVisible: Bool
    /// The left sidebar is hidden because the window was too narrow, not because
    /// the person hid it, so it returns when the window widens.
    public var isLeftAutoCollapsed: Bool
    /// Same as ``isLeftAutoCollapsed`` for the right sidebar.
    public var isRightAutoCollapsed: Bool
    /// The panel kept when only one of the two fits: the one the person showed
    /// last, else the left one.
    public var preferredPanel: Panel

    public init(
        isLeftVisible: Bool,
        isRightVisible: Bool,
        isLeftAutoCollapsed: Bool = false,
        isRightAutoCollapsed: Bool = false,
        preferredPanel: Panel = .left
    ) {
        self.isLeftVisible = isLeftVisible
        self.isRightVisible = isRightVisible
        self.isLeftAutoCollapsed = isLeftAutoCollapsed
        self.isRightAutoCollapsed = isRightAutoCollapsed
        self.preferredPanel = preferredPanel
    }

    /// The panels to show at `windowWidth`. Of the panels the person wants
    /// (shown, or collapsed here earlier), it shows both if they fit, else the
    /// preferred one alone, else the other one alone, else neither. The answer
    /// depends only on the wanted panels and the widths, so applying it twice
    /// changes nothing and a live resize never flickers a panel.
    ///
    /// - Parameters:
    ///   - windowWidth: The window's content width.
    ///   - leftWidth: The width the left sidebar takes when shown.
    ///   - rightWidth: The width the right sidebar takes when shown.
    ///   - minimumTerminalWidth: The terminal area to keep.
    public func fitting(
        windowWidth: CGFloat,
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        minimumTerminalWidth: CGFloat = SidePanelWidthFit.minimumTerminalWidth
    ) -> SidePanelWidthFit {
        guard windowWidth.isFinite, windowWidth > 0 else { return self }
        let wantsLeft = isLeftVisible || isLeftAutoCollapsed
        let wantsRight = isRightVisible || isRightAutoCollapsed
        let single = preferredPanel == .left
            ? [(wantsLeft, false), (false, wantsRight)]
            : [(false, wantsRight), (wantsLeft, false)]
        let candidates = [(wantsLeft, wantsRight)] + single
        let chosen = candidates.first { left, right in
            windowWidth - (left ? leftWidth : 0) - (right ? rightWidth : 0) >= minimumTerminalWidth
        } ?? (false, false)
        return SidePanelWidthFit(
            isLeftVisible: chosen.0,
            isRightVisible: chosen.1,
            isLeftAutoCollapsed: wantsLeft && !chosen.0,
            isRightAutoCollapsed: wantsRight && !chosen.1,
            preferredPanel: preferredPanel
        )
    }

    /// The panels to show after the person shows `panel`: that panel becomes
    /// the preferred one and stays, and the other one collapses if both do not
    /// fit. The result is what ``fitting`` keeps at the same width, so a later
    /// resize does not undo it. A panel shown in a window too narrow even for
    /// it alone stays shown; the terminal still keeps some width because the
    /// window minimum is wider than either panel, and the next window resize
    /// collapses it.
    public func showing(
        _ panel: Panel,
        windowWidth: CGFloat,
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        minimumTerminalWidth: CGFloat = SidePanelWidthFit.minimumTerminalWidth
    ) -> SidePanelWidthFit {
        var next = self
        next.preferredPanel = panel
        switch panel {
        case .left:
            next.isLeftVisible = true
            next.isLeftAutoCollapsed = false
        case .right:
            next.isRightVisible = true
            next.isRightAutoCollapsed = false
        }
        guard windowWidth.isFinite, windowWidth > 0,
              next.isLeftVisible, next.isRightVisible,
              windowWidth - leftWidth - rightWidth < minimumTerminalWidth
        else { return next }
        switch panel {
        case .left:
            next.isRightVisible = false
            next.isRightAutoCollapsed = true
        case .right:
            next.isLeftVisible = false
            next.isLeftAutoCollapsed = true
        }
        return next
    }
}
