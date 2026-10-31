import CoreGraphics

/// How a toast follows the finger and when a drag dismisses it (`CmuxMobileToastDismiss`). A toast
/// leaves the way it came: one that entered from the top goes up or sideways, one that
/// entered from the bottom goes down or sideways. Pulling the other way rubber-bands.
public struct ToastDismissal: Equatable, Sendable {
    public enum Entry: Sendable, Equatable { case top, bottom }

    public var entry: Entry
    /// Distance past which a release dismisses.
    public var distance: CGFloat = 40
    /// A flick whose predicted end passes this dismisses even if the finger moved less.
    public var predictedDistance: CGFloat = 110
    /// The pull against the exit direction follows the finger at this fraction.
    public var resistance: CGFloat = 0.2

    public init(entry: Entry) {
        self.entry = entry
    }

    /// Vertical motion toward the exit (up for a top toast, down for a bottom one) is positive.
    private func outward(_ dy: CGFloat) -> CGFloat { entry == .top ? -dy : dy }

    /// Where the toast is drawn for a finger translation.
    public func offset(for translation: CGSize) -> CGSize {
        let out = outward(translation.height)
        let dy = out >= 0 ? translation.height : translation.height * resistance
        // Sideways only once the drag is mostly sideways, so a vertical flick stays straight.
        let dx = abs(translation.width) > abs(translation.height) ? translation.width : translation.width * resistance
        return CGSize(width: dx, height: dy)
    }

    /// Whether a release dismisses.
    public func dismisses(translation: CGSize, predictedEnd: CGSize) -> Bool {
        let sideways = max(abs(translation.width), 0)
        let predictedSideways = abs(predictedEnd.width)
        if outward(translation.height) >= distance || sideways >= distance * 1.5 { return true }
        return outward(predictedEnd.height) >= predictedDistance || predictedSideways >= predictedDistance * 1.5
    }

    /// Where the toast animates to when dismissed by a drag (off in the drag's direction).
    public func exitOffset(for translation: CGSize, size: CGSize) -> CGSize {
        if abs(translation.width) > abs(outward(translation.height)) {
            return CGSize(width: (translation.width >= 0 ? 1 : -1) * (size.width + 40), height: translation.height)
        }
        return CGSize(width: translation.width, height: (entry == .top ? -1 : 1) * (size.height + 80))
    }
}

/// Where a workspace toast sits, by the screen's chrome.
///
/// - A tab page: TabsKit keeps every control at the bottom (the title pill, Back, page
///   menu, Tabs, a chat composer, a terminal's composer and key bar, the keyboard), so the
///   toast goes at the top, under the status bar, where a page has no controls and the
///   keyboard never reaches.
/// - The tab grid: its header (Back, the title, More) is at the top and every card has a
///   close button at its top corner, so the toast goes at the bottom, just above the grid's
///   bottom controls (New Tab, the tab count, Done). The grid has no keyboard.
public struct ToastPlacement: Equatable, Sendable {
    public enum Screen: Sendable, Equatable { case page, grid }

    public var screen: Screen
    /// Height of the grid's bottom controls above the bottom safe area.
    public var gridControls: CGFloat
    public var gap: CGFloat = 8

    public init(screen: Screen, gridControls: CGFloat = 56) {
        self.screen = screen
        self.gridControls = gridControls
    }

    /// The edge the toast enters from (and leaves by, with a swipe).
    public var entry: ToastDismissal.Entry { screen == .page ? .top : .bottom }

    /// Distance from the top safe area (page) or the bottom safe area (grid) to the toast.
    public var inset: CGFloat { screen == .page ? gap : gridControls + gap }

    /// The toast's frame in a screen `height` tall with `safeTop` / `safeBottom` insets.
    public func frame(toastHeight: CGFloat, screenHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CGRect {
        let y = screen == .page ? safeTop + inset : screenHeight - safeBottom - inset - toastHeight
        return CGRect(x: 0, y: y, width: .greatestFiniteMagnitude, height: toastHeight)
    }

    /// Whether the toast misses a control whose frame is `control` (screen coordinates).
    public func clears(_ control: CGRect, toastHeight: CGFloat, screenHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> Bool {
        !frame(toastHeight: toastHeight, screenHeight: screenHeight, safeTop: safeTop, safeBottom: safeBottom).intersects(control)
    }
}

extension ToastDismissal {
    /// How long a toast stays (a UI timeout, not synchronization): 4 s, longer for a line
    /// that takes longer to read (about 3 words a second, at most 12 s). A refusal that says
    /// what to do (the trust steps, 30 to 45 words) went away mid-sentence after 4 s.
    public static func lifetime(for text: String) -> Duration {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return .seconds(min(12, max(4, Double(words) / 3)))
    }
}
