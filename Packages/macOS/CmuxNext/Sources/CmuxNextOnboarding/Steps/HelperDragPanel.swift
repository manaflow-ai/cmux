import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// A glass panel docked over the System Settings window while a grant is
/// pending, about as wide as that window's list:
///
///       ^
///       |  Drag cmux Computer Use to the list above to allow Screenshots
///     < [icon] cmux Computer Use
///
/// An accent arrow that bobs up toward the list stands over the helper's
/// icon, its head above the line of text and its shaft beside it; the text
/// starts where the helper's name starts. Under them, a round back button and
/// the helper app's row to drag, styled like a row of the list it goes into.
/// The two names are white, the rest of the line secondary.
/// It never takes focus, so System Settings stays the active app. It waits
/// at the bottom center of the screen until the System Settings window is
/// on screen (a few reads while System Settings opens), then docks to it as
/// the next row of its list: the helper's row spans the list's rows and its
/// icon stands in the list's icon column. For Screenshots its top is just
/// under the pane's first list (``SystemSettingsList``, or a measured place
/// without it), so the arrow never points into "System Audio Recording Only";
/// for Accessibility (one list) it docks over the window's bottom. Then it follows that window
/// (``SystemSettingsFollower``): it moves with it, hides while it is off
/// screen, and goes back to the bottom center to look again when it closes.
final class HelperDragPanel: NSPanel {
    private static let padding: CGFloat = 12
    /// Room between the back button and the row, and between the text and the row.
    private static let gap: CGFloat = 8
    /// The helper row's leading edge from the panel's: the padding, the back button, the gap.
    static let rowLeading: CGFloat = padding + HelperPanelBackButton.side + gap
    /// The helper row is as wide as the rows of System Settings' list.
    static let width: CGFloat = rowLeading + SystemSettingsWindow.listWidth + padding
    /// The helper icon's center from the panel's leading edge: docked, it is in the list's icon column.
    static let iconCenter: CGFloat = rowLeading + HelperAppTile.iconCenter
    /// The helper row's corner; the panel's corner is concentric around it.
    static let rowRadius: CGFloat = 8
    private let onBack: () -> Void
    /// The grant the panel helps with: it decides where the panel docks.
    let pane: ComputerUsePermissionPane
    let arrow = HelperPanelArrow()
    let back = HelperPanelBackButton(target: nil, action: nil)
    /// A text field, not a chrome label: a chrome label draws one color, and this line has two
    /// (the names white, the rest secondary).
    let line: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 2
        field.isSelectable = false
        return field
    }()
    /// The lookup of a System Settings window to dock to.
    private(set) var locating: Task<Void, Never>?
    private var fallbackScreen: NSScreen?
    /// Keeps the panel on the window it docked to.
    let follower: SystemSettingsFollower
    /// Between ``beginDocking(on:)`` and ``orderOut(_:)``.
    private var shown = false
    /// Ordered out while the System Settings window is off screen (minimized, hidden, another Space).
    private(set) var isAway = false
    /// Frames set to follow the window (tests).
    private(set) var followMoves = 0

    /// `follower` stands in for the window list, the list reads and the display frames (tests).
    init(appURL: URL, pane: ComputerUsePermissionPane, onBack: @escaping () -> Void, onDrop: @escaping () -> Void,
         follower: SystemSettingsFollower? = nil) {
        self.onBack = onBack
        self.pane = pane
        let grant = OnboardingStrings.computerUseName(pane)
        let pace = LiveSettingsFollowPace()
        self.follower = follower ?? SystemSettingsFollower(reader: LiveSettingsWindowReader(), pace: pace,
                                                           list: pane == .screenRecording ? LiveSettingsListReader() : nil)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        pace.window = self
        self.follower.onEvent = { [weak self] in self?.followed($0) }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        let padding = Self.padding, gap = Self.gap
        // The text starts where the helper's name starts; the arrow stands over the helper's icon.
        let textWidth = Self.width - 2 * padding - HelperPanelBackButton.side - gap - HelperAppTile.nameInset
        line.attributedStringValue = Self.dragLine(helper: HelperAppTile.displayName(appURL), grant: grant)
        line.preferredMaxLayoutWidth = textWidth
        // A longer translation wraps to a second line and grows the panel; it is never cut.
        line.setContentCompressionResistancePriority(.required, for: .vertical)
        let tile = HelperAppTile(appURL: appURL)
        tile.onDrop = onDrop
        let card = OnboardingCardView(cornerRadius: Self.rowRadius)
        let circle = HelperPanelBackButton.makeCircle()
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [arrow, line, circle, back, card, tile] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        // Preferred, not required: a one-line text ends level with the arrow's foot (the head stands
        // above it), and the row sits `gap` under the lower of them.
        let rowTop = tile.topAnchor.constraint(equalTo: arrow.bottomAnchor, constant: gap)
        let lineFoot = line.bottomAnchor.constraint(equalTo: arrow.bottomAnchor)
        for constraint in [rowTop, lineFoot] { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            arrow.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            arrow.centerXAnchor.constraint(equalTo: tile.icon.centerXAnchor),
            lineFoot,
            line.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: padding),
            line.leadingAnchor.constraint(equalTo: tile.name.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            back.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            back.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            tile.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: gap),
            tile.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            tile.topAnchor.constraint(greaterThanOrEqualTo: arrow.bottomAnchor, constant: gap),
            tile.topAnchor.constraint(greaterThanOrEqualTo: line.bottomAnchor, constant: gap),
            rowTop,
            tile.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),
        ])
        for (under, over) in [(card, tile), (circle, back)] as [(NSView, NSView)] {
            NSLayoutConstraint.activate([
                under.leadingAnchor.constraint(equalTo: over.leadingAnchor), under.trailingAnchor.constraint(equalTo: over.trailingAnchor),
                under.topAnchor.constraint(equalTo: over.topAnchor), under.bottomAnchor.constraint(equalTo: over.bottomAnchor),
            ])
        }
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        let surface = Glass.makeOverlayPanel(content: content, cornerRadius: Self.rowRadius + padding)
        // A window's content view sizes by its frame, not constraints.
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()
        content.frame = NSRect(origin: .zero, size: size)
        contentView = surface
        ThemeScope.app.store.adopt(self)
        setContentSize(size)
        back.target = self
        back.action = #selector(backPressed)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The back button: the panel goes and the Computer Use window comes back.
    @objc func backPressed() { onBack() }

    /// "Drag **helper** to the list above to allow **grant**": the two names bold.
    static func dragLine(helper: String, grant: String) -> NSAttributedString {
        let text = OnboardingStrings.computerUseDragLine(helper: helper, grant: grant)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: Typography.system(size: TypeScale.body), .foregroundColor: Palette.textSecondary,
        ])
        let bold: [NSAttributedString.Key: Any] = [.font: Typography.system(size: TypeScale.body, weight: TypeScale.emphasis),
                                                   .foregroundColor: Palette.textPrimary]
        for name in [helper, grant] {
            let range = (text as NSString).range(of: name)
            if range.location != NSNotFound { result.addAttributes(bold, range: range) }
        }
        return result
    }

    /// Shows the panel docked to System Settings (or at the bottom center of
    /// `screen` until a System Settings window is on screen).
    func show(on screen: NSScreen?) {
        alphaValue = 0
        beginDocking(on: screen)
        orderFrontRegardless()
        Motion.overlays.animate(.fadeIn, in: contentView) { animator().alphaValue = 1 }
        arrow.bounce(true)
    }

    /// Places the panel at the bottom center of `screen` and looks for the System Settings window.
    func beginDocking(on screen: NSScreen?) {
        fallbackScreen = screen ?? NSScreen.main
        shown = true
        moveToFallback()
        dock()
    }

    /// Reads before the panel stays at its fallback place: System Settings
    /// may still be opening when Allow shows the panel.
    static let dockReads = 6

    /// Moves the panel onto the System Settings window, then follows it.
    private func dock() {
        locating?.cancel()
        let reader = follower.reader, list = follower.list
        // task-owner: a few window list reads while System Settings opens; orderOut cancels them.
        locating = Task { [weak self] in
            var backoff = Backoff(initial: .milliseconds(150), maximum: .seconds(1), jitter: 0)
            for _ in 0..<Self.dockReads {
                if let found = await reader.find() {
                    // Screenshots: where the pane's first list ends, before the first frame (nil without the grant).
                    let bottom = await list?.firstListBottom(in: found)
                    guard let self, !Task.isCancelled, shown else { return }
                    locating = nil
                    follower.follow(found, listBottom: bottom)
                    if let target = dockedFrame(for: found.bounds), target != frame {
                        // The panel glides from its waiting place when on screen; it never animates hidden.
                        if isVisible {
                            Motion.overlays.animateTimed(.panel, in: contentView) { animator().setFrame(target, display: true) }
                        } else {
                            Motion.overlays.withoutAnimation { animator().setFrame(target, display: true) }
                        }
                    }
                    return
                }
                // concurrency-allow: Backoff.wait spaces a few reads after one found no window, not a poll period.
                do { try await backoff.wait(owner: "onboarding.helper-panel.dock") } catch { return }
            }
        }
    }

    /// The panel's frame docked to a System Settings window at window-list `bounds`.
    func dockedFrame(for bounds: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let settings = SystemSettingsWindow.appKitFrame(bounds, primaryHeight: primary.frame.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? fallbackScreen
        return SystemSettingsWindow.dockedFrame(panel: frame.size, iconCenter: Self.iconCenter, settings: settings,
                                                listBottom: listBottom, visible: screen?.visibleFrame)
    }

    /// Where the pane's first list ends, from the window's top: Screenshots only (read, else
    /// measured); nil for Accessibility, which docks over the window's bottom.
    var listBottom: CGFloat? {
        pane == .screenRecording ? follower.listBottom : nil
    }

    private func moveToFallback() {
        guard let visible = fallbackScreen?.visibleFrame else { return }
        let target = SystemSettingsWindow.fallbackFrame(panel: frame.size, visible: visible)
        if target != frame { Motion.overlays.withoutAnimation { animator().setFrame(target, display: isVisible) } }
    }

    private func followed(_ event: SystemSettingsFollower.Event) {
        guard shown else { return }
        switch event {
        case .dock(let bounds):
            if let target = dockedFrame(for: bounds), target != frame {
                // Not an animation: the panel tracks the window's own move, frame for frame. The
                // zero-length group also ends a dock glide still running, so the two never fight.
                Motion.overlays.withoutAnimation { animator().setFrame(target, display: true) }
                followMoves += 1
            }
            comeBack()
        case .hide:
            isAway = true
            arrow.bounce(false)
            super.orderOut(nil)
        case .lost:
            moveToFallback()
            comeBack()
            dock()
        }
    }

    /// Shows the panel again after the window it follows was off screen.
    private func comeBack() {
        guard isAway else { return }
        isAway = false
        orderFrontRegardless()
        arrow.bounce(true)
    }

    override func orderOut(_ sender: Any?) {
        shown = false
        isAway = false
        locating?.cancel()
        locating = nil
        follower.stop()
        arrow.bounce(false)
        super.orderOut(sender)
    }
}
