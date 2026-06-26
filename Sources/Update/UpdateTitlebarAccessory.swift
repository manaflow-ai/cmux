import AppKit
import Bonsplit
import Combine
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import CmuxTestSupport
import SwiftUI

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .classic:
            return "Classic"
        case .compact:
            return "Compact"
        case .roomy:
            return "Roomy"
        case .pillGroup:
            return "Pill Group"
        case .softButtons:
            return "Soft Buttons"
        }
    }

    var config: TitlebarControlsStyleConfig {
        switch self {
        case .classic:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: HeaderChromeControlMetrics.iconSize,
                buttonSize: HeaderChromeControlMetrics.buttonSize,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: HeaderChromeControlMetrics.cornerRadius,
                hoverBackground: false
            )
        case .compact:
            return TitlebarControlsStyleConfig(
                spacing: 5,
                iconSize: 11,
                buttonSize: 18,
                badgeSize: 11,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 5,
                hoverBackground: false
            )
        case .roomy:
            return TitlebarControlsStyleConfig(
                spacing: 7,
                iconSize: 13,
                buttonSize: 22,
                badgeSize: 13,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 7,
                hoverBackground: false
            )
        case .pillGroup:
            return TitlebarControlsStyleConfig(
                spacing: 5,
                iconSize: 12,
                buttonSize: 20,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3),
                buttonBackground: false,
                buttonCornerRadius: 6,
                hoverBackground: true
            )
        case .softButtons:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: 12,
                buttonSize: 21,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: true,
                buttonCornerRadius: 6,
                hoverBackground: false
            )
        }
    }
}

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let badgeSize: CGFloat
    let badgeOffset: CGSize
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

enum TitlebarControlsVisualMetrics {
    static let verticalLift: CGFloat = 0

    static func liftedYOffset(_ yOffset: CGFloat) -> CGFloat {
        yOffset + verticalLift
    }
}

func titlebarNotificationBadgeFontSize(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(7, config.badgeSize - 6)
}

func titlebarControlPressedScale(isPressed _: Bool) -> CGFloat {
    1
}

final class TitlebarControlsViewModel: ObservableObject {
    weak var notificationsAnchorView: NSView?
}

@MainActor
final class NotificationsAnchorRegistry {
    static let shared = NotificationsAnchorRegistry()

    private let anchors = NSHashTable<NSView>.weakObjects()

    private init() {}

    func register(_ view: NSView) {
        guard !anchors.contains(view) else { return }
        anchors.add(view)
    }

    func closestAnchor(in window: NSWindow, to pointInWindow: NSPoint) -> NSView? {
        anchors.allObjects
            .compactMap { view -> (view: NSView, distance: CGFloat)? in
                guard view.window === window else { return nil }
                guard notificationsPopoverAnchorIsVisible(view) else { return nil }
                let frameInWindow = view.convert(view.bounds, to: nil)
                guard !frameInWindow.isEmpty else { return nil }
                let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
                let dx = center.x - pointInWindow.x
                let dy = center.y - pointInWindow.y
                return (view, (dx * dx) + (dy * dy))
            }
            .min { $0.distance < $1.distance }?
            .view
    }
}

@MainActor
func notificationsPopoverAnchorIsVisible(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden || candidate.alphaValue <= 0 {
            return false
        }
        current = candidate.superview
    }
    return true
}

@MainActor
func preferredNotificationsPopoverAnchor(buttonAnchor: NSView?, fallbackAnchor: NSView?) -> NSView? {
    let fallbackWindow = fallbackAnchor?.window
    guard let buttonAnchor,
          let buttonWindow = buttonAnchor.window,
          fallbackWindow == nil || buttonWindow === fallbackWindow,
          !buttonAnchor.bounds.isEmpty,
          notificationsPopoverAnchorIsVisible(buttonAnchor) else {
        return fallbackAnchor
    }
    return buttonAnchor
}

private final class DetachedNotificationsPopoverDelegate: NSObject, NSPopoverDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}

extension Notification.Name {
    static let cmuxNotificationsPopoverVisibilityDidChange = Notification.Name("cmux.notificationsPopoverVisibilityDidChange")
}

private enum NotificationsPopoverVisibilityUserInfoKey {
    static let isShown = "isShown"
    static let windowNumber = "windowNumber"
}

final class NotificationsPopoverVisibilityState: ObservableObject {
    static let shared = NotificationsPopoverVisibilityState()

    @Published private(set) var isShown = false
    @Published private(set) var shownWindowNumbers: Set<Int> = []
    private var shownPopoverIDs: Set<ObjectIdentifier> = []
    private var shownPopoverWindowNumbers: [ObjectIdentifier: Int] = [:]
    private var sourceLessShown = false

    private init() {}

    func setShown(_ newValue: Bool) {
        setShown(newValue, source: nil, windowNumber: nil)
    }

    func setShown(_ newValue: Bool, source: AnyObject?, windowNumber: Int? = nil) {
        if Thread.isMainThread {
            setShownOnMain(newValue, source: source, windowNumber: windowNumber)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.setShown(newValue, source: source, windowNumber: windowNumber)
            }
        }
    }

    func isShown(in windowNumber: Int?) -> Bool {
        guard let windowNumber else { return isShown }
        return sourceLessShown || shownWindowNumbers.contains(windowNumber)
    }

    private func setShownOnMain(_ newValue: Bool, source: AnyObject?, windowNumber: Int?) {
        if let source {
            let id = ObjectIdentifier(source)
            if newValue {
                shownPopoverIDs.insert(id)
                if let windowNumber {
                    shownPopoverWindowNumbers[id] = windowNumber
                }
            } else {
                shownPopoverIDs.remove(id)
                shownPopoverWindowNumbers.removeValue(forKey: id)
            }
        } else {
            shownPopoverIDs.removeAll()
            shownPopoverWindowNumbers.removeAll()
            sourceLessShown = newValue
        }
        updateShown()
    }

    private func updateShown() {
        let newWindowNumbers = Set(shownPopoverWindowNumbers.values)
        if shownWindowNumbers != newWindowNumbers {
            shownWindowNumbers = newWindowNumbers
        }
        let newValue = sourceLessShown || !shownPopoverIDs.isEmpty
        guard isShown != newValue else { return }
        isShown = newValue
    }

    #if DEBUG
    func resetForTesting() {
        shownPopoverIDs.removeAll()
        shownPopoverWindowNumbers.removeAll()
        sourceLessShown = false
        updateShown()
    }
    #endif
}

private func postNotificationsPopoverVisibilityDidChange(isShown: Bool, source: AnyObject? = nil, windowNumber: Int? = nil) {
    let state = NotificationsPopoverVisibilityState.shared
    state.setShown(isShown, source: source, windowNumber: windowNumber)
    var userInfo: [String: Any] = [NotificationsPopoverVisibilityUserInfoKey.isShown: state.isShown]
    if let windowNumber {
        userInfo[NotificationsPopoverVisibilityUserInfoKey.windowNumber] = windowNumber
    }
    NotificationCenter.default.post(
        name: .cmuxNotificationsPopoverVisibilityDidChange,
        object: nil,
        userInfo: userInfo
    )
}

struct NotificationsAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            NotificationsAnchorRegistry.shared.register(view)
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TitlebarControlAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AnchorNSView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

struct ShortcutHintLanePlanner {
    static func assignLanes(for intervals: [ClosedRange<CGFloat>], minSpacing: CGFloat = 4) -> [Int] {
        guard !intervals.isEmpty else { return [] }

        var laneMaxX: [CGFloat] = []
        var lanes: [Int] = []
        lanes.reserveCapacity(intervals.count)

        for interval in intervals {
            var lane = 0
            while lane < laneMaxX.count {
                let requiredMinX = laneMaxX[lane] + minSpacing
                if interval.lowerBound >= requiredMinX {
                    break
                }
                lane += 1
            }

            if lane == laneMaxX.count {
                laneMaxX.append(interval.upperBound)
            } else {
                laneMaxX[lane] = max(laneMaxX[lane], interval.upperBound)
            }
            lanes.append(lane)
        }

        return lanes
    }
}

struct ShortcutHintHorizontalPlanner {
    static func assignRightEdges(
        for intervals: [ClosedRange<CGFloat>],
        minSpacing: CGFloat = 6,
        minLeadingEdge: CGFloat = 0
    ) -> [CGFloat] {
        guard !intervals.isEmpty else { return [] }

        var assignedRightEdges = Array(repeating: CGFloat.zero, count: intervals.count)
        var nextMaxRight = CGFloat.greatestFiniteMagnitude

        for index in stride(from: intervals.count - 1, through: 0, by: -1) {
            let interval = intervals[index]
            let width = interval.upperBound - interval.lowerBound
            let preferredRightEdge = interval.upperBound
            let adjustedRightEdge = min(preferredRightEdge, nextMaxRight)
            assignedRightEdges[index] = adjustedRightEdge
            nextMaxRight = adjustedRightEdge - width - minSpacing
        }

        let assignedLeftEdges = zip(intervals, assignedRightEdges).map { interval, rightEdge in
            rightEdge - (interval.upperBound - interval.lowerBound)
        }
        if let minAssignedLeftEdge = assignedLeftEdges.min(), minAssignedLeftEdge < minLeadingEdge {
            let shift = minLeadingEdge - minAssignedLeftEdge
            assignedRightEdges = assignedRightEdges.map { $0 + shift }
        }

        return assignedRightEdges
    }
}

func titlebarShortcutHintHeight(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(14, config.iconSize + 1)
}

/// Width of a titlebar shortcut-hint pill, measured with the same font `ShortcutHintPill`
/// renders with (SF Rounded at the pill's font size). Measuring with the default
/// (non-rounded) system font underestimated command-symbol glyphs and let the pill
/// overflow its reserved slot. The `+ 12` matches the pill's 6pt horizontal padding per side.
func titlebarHintPillWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
    let pillFontSize = max(8, config.iconSize - 5)
    let scaledPillFontSize = GlobalFontMagnification.scaledSize(pillFontSize)
    let baseFont = GlobalFontMagnification.systemFont(ofSize: pillFontSize, weight: .semibold)
    let pillFont = baseFont.fontDescriptor.withDesign(.rounded)
        .flatMap { NSFont(descriptor: $0, size: scaledPillFontSize) } ?? baseFont
    let textWidth = (shortcut.displayString as NSString).size(withAttributes: [.font: pillFont]).width
    return ceil(textWidth) + 12
}

/// The rightmost edge the shortcut-hint pills occupy, in the controls' content
/// coordinate space (measured from the leading edge of the button row), after the
/// horizontal planner resolves overlaps.
///
/// This mirrors `TitlebarControlsView.titlebarHintIntervals` and the
/// `ShortcutHintHorizontalPlanner` so the accessory reserves exactly enough width for
/// the real layout. It is computed unconditionally for every command-bound slot (not
/// gated on modifier state) so the reserved width stays stable whether or not the hints
/// are currently visible. Returns 0 when no slot would show a hint.
func titlebarHintLayoutRightmostExtent(
    config: TitlebarControlsStyleConfig,
    titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX
) -> CGFloat {
    let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
    var intervals: [ClosedRange<CGFloat>] = []
    for slot in TitlebarShortcutHintActionSlot.allCases {
        let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
        guard !shortcut.isUnbound, shortcut.command else { continue }
        let width = titlebarHintPillWidth(for: shortcut, config: config)
        intervals.append(
            TitlebarControlsLayoutMetrics.hintInterval(
                for: slot,
                width: width,
                config: config,
                xOffset: xOffset
            )
        )
    }
    guard !intervals.isEmpty else { return 0 }
    return intervals.map(\.upperBound).max() ?? 0
}

enum TitlebarShortcutHintMetrics {
    static let verticalGap: CGFloat = -3
}

func titlebarShortcutHintVerticalOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
    config.buttonSize + TitlebarShortcutHintMetrics.verticalGap
}

enum TitlebarShortcutHintActionSlot: Int, CaseIterable {
    case toggleSidebar
    case showNotifications
    case newTab
    case focusHistoryBack
    case focusHistoryForward

    var action: KeyboardShortcutSettings.Action {
        switch self {
        case .toggleSidebar:
            return .toggleSidebar
        case .showNotifications:
            return .showNotifications
        case .newTab:
            return .newTab
        case .focusHistoryBack:
            return .focusHistoryBack
        case .focusHistoryForward:
            return .focusHistoryForward
        }
    }

}

enum TitlebarControlsLayoutMetrics {
    static let outerLeadingPadding: CGFloat = TitlebarControlsHitRegions.outerLeadingPadding
    static let hintTrailingBaseInset: CGFloat = 8
    static let trafficLightGap: CGFloat = 2
    /// Leading inset the controls content sits at inside the accessory; must match the
    /// `.padding(.leading, …)` applied to `controlsGroup` in the view body.
    static let hintLeadingPadding: CGFloat = HeaderChromeControlMetrics.titlebarControlsLeadingPadding
    /// Extra trailing room past the rightmost pill for its capsule stroke and shadow.
    static let hintShadowMargin: CGFloat = 4

    static func hintTrailingInset(titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX) -> CGFloat {
        max(0, ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
            + hintTrailingBaseInset
    }

    static func buttonRowWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        let buttonCount = CGFloat(TitlebarShortcutHintActionSlot.allCases.count)
        let gapCount = max(0, buttonCount - 1)
        return (buttonCount * config.buttonSize) + (gapCount * config.spacing)
    }

    static func buttonCenterX(
        for slot: TitlebarShortcutHintActionSlot,
        config: TitlebarControlsStyleConfig
    ) -> CGFloat {
        let index = CGFloat(slot.rawValue)
        return config.groupPadding.leading
            + (index * (config.buttonSize + config.spacing))
            + (config.buttonSize / 2.0)
    }

    static func hintInterval(
        for slot: TitlebarShortcutHintActionSlot,
        width: CGFloat,
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> ClosedRange<CGFloat> {
        let centerX = buttonCenterX(for: slot, config: config) + xOffset
        return (centerX - (width / 2.0))...(centerX + (width / 2.0))
    }

    static func contentSize(
        config: TitlebarControlsStyleConfig,
        titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX
    ) -> NSSize {
        // Two width requirements; reserve the larger so neither the buttons nor the
        // shortcut hints are clipped by the accessory's allocated frame.
        let buttonReservation = outerLeadingPadding
            + config.groupPadding.leading
            + buttonRowWidth(config: config)
            + config.groupPadding.trailing
            + hintTrailingInset(titlebarShortcutHintXOffset: titlebarShortcutHintXOffset)
        // Drive the reservation from the planner's actual rightmost hint edge so the
        // overlap-shift the planner applies (which the fixed inset above ignores) is
        // always covered. This is what prevents the rightmost pill from clipping.
        let hintReservation = hintLeadingPadding
            + titlebarHintLayoutRightmostExtent(
                config: config,
                titlebarShortcutHintXOffset: titlebarShortcutHintXOffset
            )
            + hintShadowMargin
        return NSSize(
            width: max(buttonReservation, hintReservation),
            height: max(
                WindowChromeMetrics.appTitlebarHeight,
                config.groupPadding.top + config.buttonSize + config.groupPadding.bottom
            )
        )
    }

    static func containerHeight(contentHeight: CGFloat, titlebarHeight: CGFloat) -> CGFloat {
        max(contentHeight, titlebarHeight)
    }

    static func leadingOffset(
        trafficLightFrame _: NSRect?,
        debugSnapshot: MinimalModeTitlebarDebugSnapshot
    ) -> CGFloat {
        MinimalModeTitlebarDebugSettings.leftControlsXOffset(
            leadingInset: debugSnapshot.leftControlsLeadingInset
        )
    }

    static func yOffset(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        trafficLightFrame: NSRect?,
        debugSnapshot: MinimalModeTitlebarDebugSnapshot
    ) -> CGFloat {
        let baseYOffset: CGFloat
        if let trafficLightFrame, !trafficLightFrame.isEmpty {
            baseYOffset = max(0, trafficLightFrame.midY - (contentHeight / 2.0))
        } else {
            baseYOffset = max(0, (containerHeight - contentHeight) / 2.0)
        }
        let debugYOffset = CGFloat(
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
                - debugSnapshot.leftControlsTopInset
        )
        return TitlebarControlsVisualMetrics.liftedYOffset(baseYOffset + debugYOffset)
    }
}

private enum TitlebarControlIconStyle {
    static let opacity = HeaderChromeIconStyle.opacity
    static let hoveredOpacity = HeaderChromeIconStyle.hoveredOpacity
    static let pressedOpacity = HeaderChromeIconStyle.pressedOpacity
    static let weight = HeaderChromeIconStyle.weight
    static let foregroundColor = HeaderChromeIconStyle.foregroundColor
    static let sidebarGlyphStrokeWidth = HeaderChromeIconStyle.sidebarGlyphStrokeWidth

    static func iconFrameSize(for config: TitlebarControlsStyleConfig) -> CGFloat {
        HeaderChromeIconStyle.iconFrameSize(forIconSize: config.iconSize)
    }
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool) -> Double {
    titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool) -> Double {
    HeaderChromeIconStyle.foregroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled)
}

func titlebarControlBackgroundOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool
) -> Double {
    titlebarControlBackgroundOpacity(config: config, isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlBackgroundOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    HeaderChromeIconStyle.backgroundOpacity(
        hoverBackground: config.hoverBackground,
        isHovering: isHovering,
        isPressed: isPressed,
        isEnabled: isEnabled
    )
}

func titlebarControlBorderOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool
) -> Double {
    titlebarControlBorderOpacity(config: config, isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlBorderOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    HeaderChromeIconStyle.borderOpacity(
        buttonBackground: config.buttonBackground,
        isHovering: isHovering,
        isPressed: isPressed,
        isEnabled: isEnabled
    )
}

struct TitlebarControlButton<Content: View>: View {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let action: () -> Void
    var isEnabled = true
    var rightClickAction: ((NSView, NSEvent) -> Void)? = nil
    @ViewBuilder let content: () -> Content

    init(
        config: TitlebarControlsStyleConfig,
        accessibilityIdentifier: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void,
        rightClickAction: ((NSView, NSEvent) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.config = config
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
        self.rightClickAction = rightClickAction
        self.content = content
    }

    var body: some View {
        Group {
            if titlebarControlsShouldTrackButtonHover(config: config) {
                hintedButton.onHover { isHovering = $0 }
            } else {
                hintedButton
            }
        }
    }

    private var baseButton: some View {
        Button(action: action) {
            content()
        }
        .disabled(!isEnabled)
        .buttonStyle(TitlebarControlButtonStyle(config: config, foregroundColor: foregroundColor))
        .frame(width: config.buttonSize, height: config.buttonSize)
        .background(TitlebarChromeGeometryReporter(keyPrefix: accessibilityIdentifier.replacingOccurrences(of: ".", with: "_")))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .focusable()
        .background(hoverBackground)
        .overlay {
            if let rightClickAction {
                TitlebarControlRightClickView(onRightMouseDown: rightClickAction)
            }
        }
        .titlebarInteractiveControl()
    }

    @ViewBuilder
    private var hintedButton: some View {
        if let hint = accessibilityHint {
            baseButton.accessibilityHint(Text(hint))
        } else {
            baseButton
        }
    }
}

struct FocusHistoryNavigationAvailability: Equatable {
    let canNavigateBack: Bool
    let canNavigateForward: Bool

    static let unavailable = FocusHistoryNavigationAvailability(
        canNavigateBack: false,
        canNavigateForward: false
    )
}

@MainActor
func focusHistoryNavigationAvailability(preferredWindow: NSWindow?) -> FocusHistoryNavigationAvailability {
    guard let manager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferredWindow) else {
        return .unavailable
    }
    return FocusHistoryNavigationAvailability(
        canNavigateBack: manager.canNavigateBack,
        canNavigateForward: manager.canNavigateForward
    )
}

private struct TitlebarControlButtonStyle: ButtonStyle {
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        TitlebarControlButtonStyleBody(
            configuration: configuration,
            config: config,
            foregroundColor: foregroundColor
        )
    }
}

private struct TitlebarControlButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let config: TitlebarControlsStyleConfig
    let foregroundColor: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .frame(width: config.buttonSize, height: config.buttonSize)
            .foregroundStyle(foregroundColor.opacity(foregroundOpacity))
            .background {
                if backgroundOpacity > 0 {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .fill(foregroundColor.opacity(backgroundOpacity))
                } else if config.buttonBackground {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                }
            }
            .overlay {
                if borderOpacity > 0 {
                    RoundedRectangle(cornerRadius: config.buttonCornerRadius, style: .continuous)
                        .stroke(foregroundColor.opacity(borderOpacity), lineWidth: 0.5)
                }
            }
            .scaleEffect(titlebarControlPressedScale(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .contentShape(Rectangle())
            .onHover { hovering in
                if titlebarControlsShouldTrackButtonHover(config: config) {
                    isHovering = hovering
                }
            }
    }

    private var foregroundOpacity: Double {
        titlebarControlForegroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var backgroundOpacity: Double {
        titlebarControlBackgroundOpacity(
            config: config,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var borderOpacity: Double {
        titlebarControlBorderOpacity(
            config: config,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }
}

private struct TitlebarControlRightClickView: NSViewRepresentable {
    let onRightMouseDown: (NSView, NSEvent) -> Void

    func makeNSView(context: Context) -> TitlebarControlRightClickNSView {
        let view = TitlebarControlRightClickNSView()
        view.onRightMouseDown = onRightMouseDown
        return view
    }

    func updateNSView(_ nsView: TitlebarControlRightClickNSView, context: Context) {
        nsView.onRightMouseDown = onRightMouseDown
    }
}

private final class TitlebarControlRightClickNSView: NSView {
    var onRightMouseDown: ((NSView, NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              NSApp.currentEvent?.type == .rightMouseDown else {
            return nil
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(self, event)
    }
}

struct TitlebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject var viewModel: TitlebarControlsViewModel
    let onToggleSidebar: () -> Void
    let onToggleNotifications: () -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void
    let visibilityMode: TitlebarControlsVisibilityMode
    @ObservedObject private var popoverVisibilityState = NotificationsPopoverVisibilityState.shared
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent
    @State private var shortcutRefreshTick = 0
    @State private var appearanceRefreshTick = 0
    @State private var isHoveringControls = false
    @State private var hostWindowNumber: Int?
    @State private var focusHistoryAvailabilityRevision: UInt64 = 0
    @State private var modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    private let titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    private let titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    @LiveSetting(\.shortcuts.showModifierHoldHints) private var showModifierHoldHints

    private struct TitlebarHintLayoutItem: Identifiable {
        let action: KeyboardShortcutSettings.Action
        let shortcut: StoredShortcut
        let width: CGFloat
        let centerX: CGFloat

        var id: String { action.rawValue }
    }

    private var modifierHoldHintsEnabled: Bool {
        showModifierHoldHints
    }

    private var shouldShowTitlebarShortcutHints: Bool {
        alwaysShowShortcutHints || (modifierHoldHintsEnabled && modifierKeyMonitor.isModifierPressed)
    }

    private func startShortcutHintMonitorIfNeeded() {
        if modifierHoldHintsEnabled {
            modifierKeyMonitor.start()
        } else {
            modifierKeyMonitor.stop()
        }
    }

    private var shouldShowControls: Bool {
        if visibilityMode == .alwaysVisible {
            return true
        }
        return isHoveringControls
            || popoverVisibilityState.isShown(in: hostWindowNumber)
            || shouldShowTitlebarShortcutHints
    }

    var body: some View {
        // Force the `.safeHelp(...)` tooltips to re-evaluate when shortcuts are changed in settings.
        // (The titlebar controls don't otherwise re-render on UserDefaults changes.)
        let _ = shortcutRefreshTick
        let _ = appearanceRefreshTick
        let _ = globalFontPercent
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let config = style.config
        let contentSize = TitlebarControlsLayoutMetrics.contentSize(
            config: config,
            titlebarShortcutHintXOffset: titlebarShortcutHintXOffset
        )
        let foregroundColor = Color(nsColor: titlebarControlForegroundNSColor(opacity: 1.0))
        controlsGroup(config: config, foregroundColor: foregroundColor)
            .padding(.leading, TitlebarControlsLayoutMetrics.hintLeadingPadding)
            .padding(.trailing, titlebarHintTrailingInset)
            .frame(width: contentSize.width, height: contentSize.height, alignment: .leading)
            .fixedSize()
            .contentShape(Rectangle())
            .opacity(shouldShowControls ? 1 : 0)
            .allowsHitTesting(shouldShowControls)
            .animation(.easeInOut(duration: 0.14), value: shouldShowControls)
            .background(
                WindowAccessor(refreshID: showModifierHoldHints) { window in
                    let nextWindowNumber = window.windowNumber
                    if hostWindowNumber != nextWindowNumber {
                        DispatchQueue.main.async {
                            if hostWindowNumber != nextWindowNumber {
                                hostWindowNumber = nextWindowNumber
                                focusHistoryAvailabilityRevision &+= 1
                            }
                        }
                    }
                    modifierKeyMonitor.setHostWindow(modifierHoldHintsEnabled ? window : nil)
                }
                .frame(width: 0, height: 0)
            )
            .onHover { hovering in
                isHoveringControls = hovering
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                shortcutRefreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .tabManagerFocusHistoryRevisionDidChange)) { _ in
                focusHistoryAvailabilityRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                focusHistoryAvailabilityRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onAppear {
                startShortcutHintMonitorIfNeeded()
            }
            .onDisappear {
                modifierKeyMonitor.stop()
                hostWindowNumber = nil
            }
            .onChange(of: showModifierHoldHints) { _, _ in
                startShortcutHintMonitorIfNeeded()
            }
    }

    private var titlebarHintTrailingInset: CGFloat {
        // Keep room for blur + shadow so the rightmost hint never clips.
        TitlebarControlsLayoutMetrics.hintTrailingInset(titlebarShortcutHintXOffset: titlebarShortcutHintXOffset)
    }

    private func titlebarHintVerticalBaseOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
        titlebarShortcutHintVerticalOffset(for: config)
    }

    @MainActor
    @ViewBuilder
    private func controlsGroup(config: TitlebarControlsStyleConfig, foregroundColor: Color) -> some View {
        let hintLayoutItems = titlebarHintLayoutItems(config: config)
        let focusHistoryAvailability = focusHistoryNavigationAvailabilitySnapshot
        let badgeBaseFontSize = titlebarNotificationBadgeFontSize(for: config) / max(1, GlobalFontMagnification.scale(for: globalFontPercent))
        let content = HStack(spacing: config.spacing) {
            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.toggleSidebar",
                accessibilityLabel: String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"),
                accessibilityHint: String(localized: "titlebar.sidebar.accessibilityHint", defaultValue: "Show or hide the sidebar"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.toggleSidebar")
                #endif
                onToggleSidebar()
            },
                rightClickAction: { anchorView, event in
                    CmuxExtensionSidebarSelection.showMenu(anchorView: anchorView, event: event)
                }) {
                sidebarIconLabel(config: config, iconGeometryKeyPrefix: "titlebarControl_toggleSidebarIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.showNotifications",
                accessibilityLabel: String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"),
                accessibilityHint: String(localized: "titlebar.notifications.accessibilityHint", defaultValue: "Show notifications"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.notifications")
                #endif
                onToggleNotifications()
            }) {
                ZStack(alignment: .topTrailing) {
                    iconLabel(
                        systemName: "bell",
                        config: config,
                        iconGeometryKeyPrefix: "titlebarControl_showNotificationsIcon"
                    )

                    if notificationStore.unreadCount > 0 {
                        Text("\(min(notificationStore.unreadCount, 99))")
                            // Fixed-size badge; cap effective glyph size.
                            .cmuxFont(size: badgeBaseFontSize, weight: .semibold)
                            .foregroundColor(.white)
                            .frame(width: config.badgeSize, height: config.badgeSize)
                            .background(Circle().fill(cmuxAccentColor()))
                            .offset(x: config.badgeOffset.width, y: config.badgeOffset.height)
                    }
                }
                .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .background(NotificationsAnchorView { viewModel.notificationsAnchorView = $0 })
            .safeHelp(KeyboardShortcutSettings.Action.showNotifications.tooltip(String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.newTab",
                accessibilityLabel: String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"),
                accessibilityHint: String(localized: "titlebar.newWorkspace.accessibilityHint", defaultValue: "Create a new workspace"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.newTab")
                #endif
                onNewTab()
            },
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: anchorView, event: event)
                }) {
                iconLabel(systemName: "plus", config: config, iconGeometryKeyPrefix: "titlebarControl_newTabIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.focusHistoryBack",
                accessibilityLabel: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"),
                action: onFocusHistoryBack,
                isEnabled: focusHistoryAvailability.canNavigateBack,
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: anchorView, event: event, direction: .back)
                }
            ) {
                iconLabel(systemName: "arrow.left", config: config, iconGeometryKeyPrefix: "titlebarControl_focusHistoryBackIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.focusHistoryBack.tooltip(String(localized: "menu.history.focusBack", defaultValue: "Focus Back")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.focusHistoryForward",
                accessibilityLabel: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"),
                action: onFocusHistoryForward,
                isEnabled: focusHistoryAvailability.canNavigateForward,
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: anchorView, event: event, direction: .forward)
                }
            ) {
                iconLabel(systemName: "arrow.right", config: config, iconGeometryKeyPrefix: "titlebarControl_focusHistoryForwardIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.focusHistoryForward.tooltip(String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")))

        }
        .accessibilityElement(children: .contain)

        let paddedContent = content.padding(config.groupPadding)

        if config.groupBackground {
            paddedContent
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        } else {
            paddedContent
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        }
    }

    @MainActor
    private var focusHistoryNavigationAvailabilitySnapshot: FocusHistoryNavigationAvailability {
        let _ = focusHistoryAvailabilityRevision
        return focusHistoryNavigationAvailability(preferredWindow: focusHistoryTargetWindow)
    }

    @MainActor
    private var focusHistoryTargetWindow: NSWindow? {
        if let hostWindowNumber,
           let hostWindow = NSApp.windows.first(where: { $0.windowNumber == hostWindowNumber }) {
            return hostWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func titlebarHintLayoutItems(config: TitlebarControlsStyleConfig) -> [TitlebarHintLayoutItem] {
        let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
        let intervals = titlebarHintIntervals(config: config, xOffset: xOffset)
        guard !intervals.isEmpty else { return [] }

        var items: [TitlebarHintLayoutItem] = []
        items.reserveCapacity(intervals.count)
        for item in intervals {
            items.append(
                TitlebarHintLayoutItem(
                    action: item.action,
                    shortcut: item.shortcut,
                    width: item.width,
                    centerX: (item.interval.lowerBound + item.interval.upperBound) / 2.0
                )
            )
        }
        return items
    }

    private func titlebarHintIntervals(
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> [(action: KeyboardShortcutSettings.Action, shortcut: StoredShortcut, width: CGFloat, interval: ClosedRange<CGFloat>)] {
        guard shouldShowTitlebarShortcutHints else { return [] }

        return TitlebarShortcutHintActionSlot.allCases.compactMap { slot in
            let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
            guard ShortcutHintTitlebarPolicy.shouldShow(
                shortcut: shortcut,
                alwaysShowShortcutHints: alwaysShowShortcutHints,
                modifierPressed: modifierKeyMonitor.isModifierPressed,
                modifierHoldHintsEnabled: modifierHoldHintsEnabled
            ) else { return nil }

            let width = titlebarHintWidth(for: shortcut, config: config)
            let interval = TitlebarControlsLayoutMetrics.hintInterval(
                for: slot,
                width: width,
                config: config,
                xOffset: xOffset
            )
            return (slot.action, shortcut, width, interval)
        }
    }

    private func titlebarHintWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
        titlebarHintPillWidth(for: shortcut, config: config)
    }

    @ViewBuilder
    private func titlebarShortcutHintOverlay(
        items: [TitlebarHintLayoutItem],
        config: TitlebarControlsStyleConfig
    ) -> some View {
        let yOffset = config.groupPadding.top
            + titlebarHintVerticalBaseOffset(for: config)
            + ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)

        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(items) { item in
                titlebarShortcutHintPill(shortcut: item.shortcut, config: config)
                    .accessibilityIdentifier("titlebarShortcutHint.\(item.action.rawValue)")
                    .frame(width: item.width, alignment: .center)
                    .background(TitlebarChromeGeometryReporter(keyPrefix: "titlebarShortcutHint_\(item.action.rawValue)"))
                    .position(
                        x: item.centerX,
                        y: yOffset + titlebarShortcutHintHeight(for: config) / 2.0
                    )
                    .shortcutHintTransition()
            }
        }
        .shortcutHintVisibilityAnimation(value: shouldShowTitlebarShortcutHints)
        .allowsHitTesting(false)
    }

    private func titlebarShortcutHintPill(
        shortcut: StoredShortcut,
        config: TitlebarControlsStyleConfig
    ) -> some View {
        ShortcutHintPill(shortcut: shortcut, fontSize: max(8, config.iconSize - 5))
            .frame(minHeight: titlebarShortcutHintHeight(for: config))
    }

    @ViewBuilder
    private func iconLabel(
        systemName: String,
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil
    ) -> some View {
        titlebarIconChrome(config: config, iconGeometryKeyPrefix: iconGeometryKeyPrefix) {
            CmuxSystemSymbolImage(systemName: systemName, pointSize: config.iconSize, weight: TitlebarControlIconStyle.weight)
        }
    }

    @ViewBuilder
    private func sidebarIconLabel(
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil
    ) -> some View {
        titlebarIconChrome(config: config, iconGeometryKeyPrefix: iconGeometryKeyPrefix) {
            TitlebarSidebarGlyph(iconSize: config.iconSize)
        }
    }

    @ViewBuilder
    private func titlebarIconChrome<Icon: View>(
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        icon()
            .frame(
                width: TitlebarControlIconStyle.iconFrameSize(for: config),
                height: TitlebarControlIconStyle.iconFrameSize(for: config)
            )
            .background(TitlebarChromeGeometryReporter(keyPrefix: iconGeometryKeyPrefix ?? ""))
    }
}

private struct TitlebarSidebarGlyph: View {
    let iconSize: CGFloat

    var body: some View {
        TitlebarSidebarGlyphShape()
            .stroke(
                style: StrokeStyle(
                    lineWidth: TitlebarControlIconStyle.sidebarGlyphStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: max(13, iconSize + 2), height: max(11, iconSize - 1))
    }
}

private struct TitlebarSidebarGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
        path.addRoundedRect(
            in: insetRect,
            cornerSize: CGSize(width: 2, height: 2)
        )

        let dividerX = insetRect.minX + insetRect.width * 0.36
        path.move(to: CGPoint(x: dividerX, y: insetRect.minY + 1.5))
        path.addLine(to: CGPoint(x: dividerX, y: insetRect.maxY - 1.5))
        return path
    }
}

private struct TitlebarControlsGapDragView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig

    func makeNSView(context: Context) -> GapDragView {
        let view = GapDragView()
        view.config = config
        return view
    }

    func updateNSView(_ nsView: GapDragView, context: Context) {
        nsView.config = config
    }

    final class GapDragView: NSView {
        var config = TitlebarControlsStyle.classic.config

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            guard bounds.contains(point) else { return nil }
            guard !TitlebarControlsHitRegions.pointFallsInButtonColumn(point, config: config) else {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                let action = performStandardTitlebarDoubleClick(window: window)
                if action != nil {
                    return
                }
            }

            guard !isWindowDragSuppressed(window: window) else { return }

            if let window {
                withTemporaryWindowMovableEnabled(window: window) {
                    window.performDrag(with: event)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct MinimalModeTitlebarButtonHitRegionView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig

    func makeNSView(context: Context) -> ButtonHitRegionView {
        let view = ButtonHitRegionView()
        view.config = config
        return view
    }

    func updateNSView(_ nsView: ButtonHitRegionView, context: Context) {
        nsView.config = config
        MinimalModeTitlebarControlHitRegionRegistry.register(nsView)
    }

    final class ButtonHitRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        var config = TitlebarControlsStyle.classic.config

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
            } else {
                MinimalModeTitlebarControlHitRegionRegistry.register(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
            minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
        }

        func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot? {
            TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config)
        }

        deinit {
            MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
        }
    }
}

struct HiddenTitlebarSidebarControlsView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onToggleNotifications: (NSView?) -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void
    @StateObject private var viewModel = TitlebarControlsViewModel()
    @ObservedObject private var popoverVisibilityState = NotificationsPopoverVisibilityState.shared
    @State private var isHoveringHost = false
    @State private var isHoveringWindowChrome = false
    @State private var hostWindowNumber: Int?
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue

    private var shouldPinControls: Bool {
        isHoveringHost || isHoveringWindowChrome || popoverVisibilityState.isShown(in: hostWindowNumber)
    }

    var body: some View {
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic

        ZStack(alignment: .leading) {
            WindowAccessor { window in
                let nextWindowNumber = window.windowNumber
                let nextHoveringWindowChrome = MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == nextWindowNumber
                if hostWindowNumber != nextWindowNumber || isHoveringWindowChrome != nextHoveringWindowChrome {
                    DispatchQueue.main.async {
                        if hostWindowNumber != nextWindowNumber {
                            hostWindowNumber = nextWindowNumber
                        }
                        if isHoveringWindowChrome != nextHoveringWindowChrome {
                            isHoveringWindowChrome = nextHoveringWindowChrome
                        }
                    }
                }
                #if DEBUG
                TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: window)
                _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    payload["minimalSidebarHostWindowNumber"] = String(nextWindowNumber)
                    payload["minimalSidebarHostPinned"] = String(
                        isHoveringHost || nextHoveringWindowChrome || popoverVisibilityState.isShown(in: nextWindowNumber)
                    )
                }
                #endif
            }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
            .allowsHitTesting(false)

            TitlebarControlsView(
                notificationStore: notificationStore,
                viewModel: viewModel,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: { [viewModel] in
                    onToggleNotifications(viewModel.notificationsAnchorView)
                },
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward,
                visibilityMode: .alwaysVisible
            )
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
                alignment: .leading
            )
            .opacity(shouldPinControls ? 1 : 0)
            .allowsHitTesting(shouldPinControls)
            .accessibilityHidden(true)
            .animation(.easeInOut(duration: 0.14), value: shouldPinControls)

            TitlebarControlsGapDragView(config: style.config)
                .frame(
                    width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                    height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
                )

            MinimalModeSidebarControlActionProxyView(
                config: style.config,
                requiresRevealedState: true
            ) { slot, anchorView, _ in
                switch slot {
                case .toggleSidebar:
                    onToggleSidebar()
                case .showNotifications:
                    onToggleNotifications(anchorView)
                case .newTab:
                    onNewTab()
                case .focusHistoryBack:
                    let availability = focusHistoryNavigationAvailability(
                        preferredWindow: hostWindowForFocusHistoryNavigation
                    )
                    guard availability.canNavigateBack else { return }
                    onFocusHistoryBack()
                case .focusHistoryForward:
                    let availability = focusHistoryNavigationAvailability(
                        preferredWindow: hostWindowForFocusHistoryNavigation
                    )
                    guard availability.canNavigateForward else { return }
                    onFocusHistoryForward()
                }
            }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )

            PassthroughHoverTrackingView(capturesPassiveHits: !shouldPinControls) { isHoveringHost = $0 }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )

        }
        .frame(
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
            alignment: .leading
        )
        .background(MinimalModeTitlebarButtonHitRegionView(config: style.config))
        .onReceive(MinimalModeSidebarChromeHoverState.shared.$hoveredWindowNumber) { hoveredWindowNumber in
            isHoveringWindowChrome = hostWindowNumber == hoveredWindowNumber
            #if DEBUG
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["minimalSidebarObservedHoverWindowNumber"] = hoveredWindowNumber.map(String.init) ?? "nil"
                payload["minimalSidebarObservedHostWindowNumber"] = hostWindowNumber.map(String.init) ?? "nil"
                payload["minimalSidebarObservedPinned"] = String(shouldPinControls)
            }
            #endif
        }
        .onDisappear {
            isHoveringHost = false
            isHoveringWindowChrome = false
            if let hostWindowNumber {
                MinimalModeSidebarChromeHoverState.shared.setHovering(false, windowNumber: hostWindowNumber)
            }
            hostWindowNumber = nil
        }
    }

    @MainActor
    private var hostWindowForFocusHistoryNavigation: NSWindow? {
        if let hostWindowNumber,
           let hostWindow = NSApp.windows.first(where: { $0.windowNumber == hostWindowNumber }) {
            return hostWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }
}

enum TitlebarControlsVisibilityMode {
    case alwaysVisible
    case onHover
}

func minimalModePassthroughHoverTrackerCapturesHit(
    capturesPassiveHits: Bool,
    eventType: NSEvent.EventType?,
    pressedMouseButtons: Int,
    boundsContainsPoint: Bool
) -> Bool {
    guard boundsContainsPoint, pressedMouseButtons == 0 else { return false }
    switch eventType {
    case nil, .mouseMoved, .mouseEntered, .mouseExited:
        return capturesPassiveHits
    default:
        return false
    }
}

private struct PassthroughHoverTrackingView: NSViewRepresentable {
    let capturesPassiveHits: Bool
    let onHoverChanged: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.capturesPassiveHits = capturesPassiveHits
        view.onHoverChanged = onHoverChanged
        return view
    }
    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.capturesPassiveHits = capturesPassiveHits
        nsView.onHoverChanged = onHoverChanged
    }

    final class TrackingView: NSView {
        var capturesPassiveHits = true
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var localMouseMonitor: Any?
        private var isHovering = false
        private weak var mouseMovedWindow: NSWindow?
        private var isTrackingMouseMovedEvents = false

        deinit {
            removeLocalMouseMonitor()
            stopMouseMovedTracking()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard NSEvent.pressedMouseButtons == 0 else { return nil }
            let event = NSApp.currentEvent
            switch event?.type {
            case .none:
                refreshHoverForHitTest(event: event)
            case .mouseMoved, .mouseEntered, .mouseExited:
                refreshHoverForHitTest(event: event)
            default:
                return nil
            }
            return minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: capturesPassiveHits,
                eventType: event?.type,
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                boundsContainsPoint: true
            ) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                refreshMouseMovedTracking(in: window)
                installLocalMouseMonitorIfNeeded()
                updateHoverFromCurrentMouseLocation()
                recordFrameForUITest()
            } else {
                stopMouseMovedTracking()
                removeLocalMouseMonitor()
                emitHoverChanged(false)
            }
        }

        private func refreshMouseMovedTracking(in window: NSWindow) {
            guard !isTrackingMouseMovedEvents || mouseMovedWindow !== window else { return }
            stopMouseMovedTracking()
            WindowMouseMovedEventsCoordinator.enable(for: window, owner: self)
            mouseMovedWindow = window
            isTrackingMouseMovedEvents = true
        }

        private func stopMouseMovedTracking() {
            if let mouseMovedWindow {
                WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
            } else {
                WindowMouseMovedEventsCoordinator.disableOwner(self)
            }
            mouseMovedWindow = nil
            isTrackingMouseMovedEvents = false
        }

        override func layout() {
            super.layout()
            recordFrameForUITest()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseExited(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(from: event)
        }

        private func installLocalMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateHover(from: event)
                return event
            }
        }

        private func removeLocalMouseMonitor() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
        }

        private func updateHover(from event: NSEvent) {
            guard let window else {
                emitHoverChanged(false)
                return
            }

            let pointInWindow = event.window === window
                ? event.locationInWindow
                : window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func updateHoverFromCurrentMouseLocation() {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func refreshHoverForHitTest(event: NSEvent?) {
            if let event {
                updateHover(from: event)
            } else {
                updateHoverFromCurrentMouseLocation()
            }
        }

        private func emitHoverChanged(_ newValue: Bool) {
            guard isHovering != newValue else { return }
            isHovering = newValue
            onHoverChanged?(newValue)
        }

        private func recordFrameForUITest() {
            #if DEBUG
            guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
            guard window != nil else { return }
            let frameInWindow = convert(bounds, to: nil)
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["minimalSidebarHostFrameInWindow"] = NSStringFromRect(frameInWindow)
            }
            #endif
        }
    }
}

struct TitlebarControlsLayoutSnapshot: Equatable {
    let contentSize: NSSize
    let containerHeight: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
}

func titlebarControlsShouldTrackButtonHover(config: TitlebarControlsStyleConfig) -> Bool {
    true
}

func titlebarControlsShouldScheduleForViewSizeChange(
    previous: NSSize,
    current: NSSize,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard current.width > 0, current.height > 0 else { return false }
    guard previous.width > 0, previous.height > 0 else { return true }
    return abs(previous.width - current.width) > tolerance
        || abs(previous.height - current.height) > tolerance
}

func titlebarControlsShouldApplyLayout(
    previous: TitlebarControlsLayoutSnapshot?,
    next: TitlebarControlsLayoutSnapshot,
    tolerance: CGFloat = 0.5
) -> Bool {
    guard let previous else { return true }
    return abs(previous.contentSize.width - next.contentSize.width) > tolerance
        || abs(previous.contentSize.height - next.contentSize.height) > tolerance
        || abs(previous.containerHeight - next.containerHeight) > tolerance
        || abs(previous.xOffset - next.xOffset) > tolerance
        || abs(previous.yOffset - next.yOffset) > tolerance
}

enum TitlebarWindowGeometryNotifications {
    static let names: [Notification.Name] = [
        NSWindow.didResizeNotification,
        NSWindow.didEndLiveResizeNotification,
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
        NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification
    ]
}

final class TitlebarControlsAccessoryViewController: NSTitlebarAccessoryViewController, NSPopoverDelegate {
    private let hostingView: NonDraggableHostingView<AnyView>
    private let containerView: NSView
    private let notificationStore: TerminalNotificationStore
    private lazy var notificationsPopover: NSPopover = makeNotificationsPopover()
    private var pendingSizeUpdate = false
    private var intrinsicSizeNeedsRefresh = true
    private var cachedContentSize: NSSize?
    private var lastObservedViewSize: NSSize = .zero
    private var lastAppliedLayoutSnapshot: TitlebarControlsLayoutSnapshot?
    private weak var observedWindow: NSWindow?
    private var windowGeometryObservers: [NSObjectProtocol] = []
    private let viewModel = TitlebarControlsViewModel()
    private var userDefaultsObserver: NSObjectProtocol?
    var popoverIsShownForTesting: Bool { notificationsPopover.isShown }
    private var showsWorkspaceTitlebar: Bool { !WorkspacePresentationModeSettings.isMinimal() }

    init(notificationStore: TerminalNotificationStore, settingsRuntime: SettingsRuntime?) {
        let containerView = TitlebarAccessoryContainerView()
        self.containerView = containerView
        self.notificationStore = notificationStore
        let toggleSidebar = { [weak containerView] in
            _ = AppDelegate.shared?.toggleSidebarInActiveMainWindow(preferredWindow: containerView?.window)
        }
        let toggleNotifications: () -> Void = { [weak containerView] in
            _ = AppDelegate.shared?.toggleNotificationsPopover(animated: true, anchorView: containerView)
        }
        let newTab = { _ = AppDelegate.shared?.performNewWorkspaceAction(debugSource: "titlebar.accessoryNewWorkspace") }
        let focusHistoryBack = { [weak containerView] in
            _ = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: containerView?.window)?.navigateBack()
        }
        let focusHistoryForward = { [weak containerView] in
            _ = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: containerView?.window)?.navigateForward()
        }
        let rootView = TitlebarControlsView(
            notificationStore: notificationStore,
            viewModel: viewModel,
            onToggleSidebar: toggleSidebar,
            onToggleNotifications: toggleNotifications,
            onNewTab: newTab,
            onFocusHistoryBack: focusHistoryBack,
            onFocusHistoryForward: focusHistoryForward,
            visibilityMode: .alwaysVisible
        )
        hostingView = NonDraggableHostingView(
            rootView: AnyView(
                rootView.environment(\.settingsRuntime, settingsRuntime)
            )
        )

        super.init(nibName: nil, bundle: nil)

        view = containerView
        containerView.translatesAutoresizingMaskIntoConstraints = true
        // The shortcut-hint pills (and button backgrounds) sit below the button
        // row and overflow the accessory's titlebar-height content frame on
        // purpose. macOS 26.5 began re-deriving `layer.masksToBounds` from the
        // AppKit `clipsToBounds` property on every layout pass, which clobbered
        // a bare `layer?.masksToBounds = false` write and re-clipped that
        // overflow (the hint captions got cut off at the bottom). Set
        // `clipsToBounds = false` on both the container and the hosting view so
        // the non-clipping intent persists across layout on every macOS version.
        containerView.wantsLayer = true
        containerView.clipsToBounds = false
        containerView.layer?.masksToBounds = false
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.clipsToBounds = false
        hostingView.layer?.masksToBounds = false
        containerView.addSubview(hostingView)

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWorkspaceTitlebarVisibility()
            if self?.showsWorkspaceTitlebar == true {
                self?.restoreSizeAfterMinimalMode()
                self?.scheduleSizeUpdate()
            }
        }

        applyWorkspaceTitlebarVisibility()
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
        removeWindowGeometryObservers()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateObservedWindowIfNeeded()
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let observedWindowChanged = updateObservedWindowIfNeeded()
        let currentViewSize = view.bounds.size
        guard titlebarControlsShouldScheduleForViewSizeChange(
            previous: lastObservedViewSize,
            current: currentViewSize
        ) || observedWindowChanged else {
            return
        }
        lastObservedViewSize = currentViewSize
        scheduleSizeUpdate(invalidateIntrinsicSize: true, invalidateLayout: observedWindowChanged)
    }

    @discardableResult
    private func updateObservedWindowIfNeeded() -> Bool {
        let currentWindow = view.window
        guard currentWindow !== observedWindow else { return false }
        removeWindowGeometryObservers()
        observedWindow = currentWindow
        guard let currentWindow else { return true }
        let center = NotificationCenter.default
        windowGeometryObservers = TitlebarWindowGeometryNotifications.names.map { name in
            center.addObserver(forName: name, object: currentWindow, queue: .main) { [weak self] _ in
                self?.scheduleSizeUpdate(invalidateIntrinsicSize: true, invalidateLayout: true)
            }
        }
        return true
    }

    private func removeWindowGeometryObservers() {
        let center = NotificationCenter.default
        for observer in windowGeometryObservers {
            center.removeObserver(observer)
        }
        windowGeometryObservers.removeAll()
    }

    private func scheduleSizeUpdate(
        invalidateIntrinsicSize: Bool = false,
        invalidateLayout: Bool = false
    ) {
        updateObservedWindowIfNeeded()
        if invalidateLayout {
            lastAppliedLayoutSnapshot = nil
        }
        if invalidateIntrinsicSize {
            intrinsicSizeNeedsRefresh = true
        }
        guard !pendingSizeUpdate else { return }
        pendingSizeUpdate = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingSizeUpdate = false
            self?.updateSize()
        }
    }

    private func updateSize() {
        updateObservedWindowIfNeeded()
        applyWorkspaceTitlebarVisibility()
        guard showsWorkspaceTitlebar else { return }
        let styleRawValue = UserDefaults.standard.integer(forKey: "titlebarControlsStyle")
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let contentSize = TitlebarControlsLayoutMetrics.contentSize(config: style.config)
        if intrinsicSizeNeedsRefresh {
            hostingView.invalidateIntrinsicContentSize()
            intrinsicSizeNeedsRefresh = false
        }
        cachedContentSize = contentSize

        guard contentSize.width > 0, contentSize.height > 0 else { return }
        let closeButton = view.window?.standardWindowButton(.closeButton)
        let titlebarView = closeButton?.superview
        let trafficLightFrame = closeButton.map { button in
            view.convert(button.convert(button.bounds, to: nil), from: nil)
        }
#if DEBUG
        TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: view.window)
#endif
        let titlebarHeight = (titlebarView?.frame.height ?? 0) > 0
            ? titlebarView?.frame.height ?? contentSize.height
            : view.window.map { window in
                window.frame.height - window.contentLayoutRect.height
            } ?? contentSize.height
        let containerHeight = TitlebarControlsLayoutMetrics.containerHeight(
            contentHeight: contentSize.height,
            titlebarHeight: titlebarHeight
        )
        let debugSnapshot = MinimalModeTitlebarDebugSettings.snapshot()
        let xOffset = TitlebarControlsLayoutMetrics.leadingOffset(
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: debugSnapshot
        )
        let yOffset = TitlebarControlsLayoutMetrics.yOffset(
            contentHeight: contentSize.height,
            containerHeight: containerHeight,
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: debugSnapshot
        )
        let nextLayoutSnapshot = TitlebarControlsLayoutSnapshot(
            contentSize: contentSize,
            containerHeight: containerHeight,
            xOffset: xOffset,
            yOffset: yOffset
        )
        guard titlebarControlsShouldApplyLayout(
            previous: lastAppliedLayoutSnapshot,
            next: nextLayoutSnapshot
        ) else {
            return
        }
        lastAppliedLayoutSnapshot = nextLayoutSnapshot
        let containerWidth = contentSize.width + abs(xOffset)
        preferredContentSize = NSSize(width: containerWidth, height: containerHeight)
        containerView.setFrameSize(NSSize(width: containerWidth, height: containerHeight))
        hostingView.frame = NSRect(x: xOffset, y: yOffset, width: contentSize.width, height: contentSize.height)
    }

    private func applyWorkspaceTitlebarVisibility() {
        let shouldShow = showsWorkspaceTitlebar
        self.isHidden = !shouldShow
        view.isHidden = !shouldShow
        view.alphaValue = shouldShow ? 1 : 0
        if !shouldShow {
            preferredContentSize = .zero
        }
    }

    /// Restore the accessory size after it was zeroed in minimal mode.
    /// Seeds the hosting view with a non-zero frame before deterministic sizing
    /// runs again after the view was collapsed.
    private func restoreSizeAfterMinimalMode() {
        guard showsWorkspaceTitlebar else { return }
        let seed = cachedContentSize ?? NSSize(width: 200, height: 28)
        if hostingView.frame.size == .zero || containerView.frame.size == .zero {
            containerView.frame.size = seed
            hostingView.frame.size = seed
        }
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    func toggleNotificationsPopover(animated: Bool = true, externalAnchor: NSView? = nil) {
        if notificationsPopover.isShown {
            notificationsPopover.animates = animated
            notificationsPopover.performClose(nil)
            return
        }
        // Recreate content view each time to avoid stale observers when popover is hidden
        let hostingController = NSHostingController(
            rootView: NotificationsPopoverView(
                notificationStore: notificationStore,
                onDismiss: { [weak notificationsPopover] in
                    notificationsPopover?.performClose(nil)
                }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = .clear
        notificationsPopover.contentViewController = hostingController

        guard let window = externalAnchor?.window ?? view.window ?? hostingView.window ?? NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }

        // Force layout to ensure geometry is current.
        contentView.layoutSubtreeIfNeeded()

        // Use external anchor (e.g. fullscreen sidebar controls) if provided.
        if let externalAnchor, externalAnchor.window != nil {
            let anchorView = preferredNotificationsPopoverAnchor(
                buttonAnchor: viewModel.notificationsAnchorView,
                fallbackAnchor: externalAnchor
            ) ?? externalAnchor
            let anchorContentView = anchorView.window?.contentView ?? contentView
            anchorContentView.layoutSubtreeIfNeeded()
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: anchorContentView)
            if !anchorRect.isEmpty {
                notificationsPopover.animates = animated
                notificationsPopover.show(relativeTo: anchorRect, of: anchorContentView, preferredEdge: .maxY)
                postNotificationsPopoverVisibilityDidChange(
                    isShown: true,
                    source: notificationsPopover,
                    windowNumber: anchorView.window?.windowNumber ?? window.windowNumber
                )
                return
            }
        }

        if let anchorView = viewModel.notificationsAnchorView, anchorView.window != nil, !isHidden {
            anchorView.superview?.layoutSubtreeIfNeeded()
            let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
            if !anchorRect.isEmpty {
                notificationsPopover.animates = animated
                notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
                postNotificationsPopoverVisibilityDidChange(
                    isShown: true,
                    source: notificationsPopover,
                    windowNumber: window.windowNumber
                )
                return
            }
        }

        // Fallback: position near top-left of the window content.
        let bounds = contentView.bounds
        let anchorRect = NSRect(x: 12, y: bounds.maxY - 8, width: 1, height: 1)
        notificationsPopover.animates = animated
        notificationsPopover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
        postNotificationsPopoverVisibilityDidChange(
            isShown: true,
            source: notificationsPopover,
            windowNumber: window.windowNumber
        )
    }

    func dismissNotificationsPopover() {
        if notificationsPopover.isShown {
            notificationsPopover.performClose(nil)
        }
    }

    private func makeNotificationsPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
        // Content view controller is set dynamically in toggleNotificationsPopover
        return popover
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Clear the content view controller to stop SwiftUI observers when popover is hidden
        notificationsPopover.contentViewController = nil
        postNotificationsPopoverVisibilityDidChange(isShown: false, source: notificationsPopover)
    }
}

private enum NotificationsPopoverMetrics {
    static let defaultWidth: CGFloat = 560
    static let defaultHeight: CGFloat = 760
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 320
    static let maxWidth: CGFloat = 1000
    static let maxHeight: CGFloat = 1200
}

private struct NotificationsPopoverView: View {
    @ObservedObject var notificationStore: TerminalNotificationStore
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    let onDismiss: () -> Void

    @AppStorage("cmux.notifications.popover.width")
    private var savedWidth: Double = Double(NotificationsPopoverMetrics.defaultWidth)
    @AppStorage("cmux.notifications.popover.height")
    private var savedHeight: Double = Double(NotificationsPopoverMetrics.defaultHeight)

    // Live size while the user drags the resize handle. We avoid writing through @AppStorage
    // on every mouseDragged event because each write hits UserDefaults and posts
    // UserDefaults.didChangeNotification, which wakes up every observer in the app.
    @State private var liveWidth: CGFloat?
    @State private var liveHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: clampedWidth, height: clampedHeight)
        .animation(nil, value: clampedWidth)
        .animation(nil, value: clampedHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
        }
    }

    // Cap against the current screen so the popover (and especially the bottom-right resize
    // handle) stays reachable on small displays even if saved defaults came from a larger one.
    private static let screenMargin: CGFloat = 80

    // The popover doesn't take key, so its host (anchor) window remains key. Use that window's
    // screen so multi-monitor setups clamp against the display where the popover actually
    // appears, not whatever NSScreen.main happens to point at.
    private var popoverScreen: NSScreen? {
        NSApp.keyWindow?.screen ?? NSScreen.main
    }

    private var screenMaxWidth: CGFloat {
        let screenWidth = popoverScreen?.visibleFrame.width ?? NotificationsPopoverMetrics.maxWidth
        return max(NotificationsPopoverMetrics.minWidth, screenWidth - Self.screenMargin)
    }

    private var screenMaxHeight: CGFloat {
        let screenHeight = popoverScreen?.visibleFrame.height ?? NotificationsPopoverMetrics.maxHeight
        return max(NotificationsPopoverMetrics.minHeight, screenHeight - Self.screenMargin)
    }

    private var clampedWidth: CGFloat {
        let raw = liveWidth ?? CGFloat(savedWidth)
        let upper = min(NotificationsPopoverMetrics.maxWidth, screenMaxWidth)
        return min(upper, max(NotificationsPopoverMetrics.minWidth, raw))
    }

    private var clampedHeight: CGFloat {
        let raw = liveHeight ?? CGFloat(savedHeight)
        let upper = min(NotificationsPopoverMetrics.maxHeight, screenMaxHeight)
        return min(upper, max(NotificationsPopoverMetrics.minHeight, raw))
    }

    // Invisible bottom-right corner resize region. NSPopover has no native resize chrome and
    // there's no first-class SwiftUI resize API for it. SwiftUI's `DragGesture` reports
    // translations in a local coordinate space that is literally being resized under the
    // cursor as the user drags, which produces dimension oscillation. We use an AppKit
    // representable that tracks `NSEvent.mouseLocation` in stable global screen coordinates.
    private var resizeHandle: some View {
        ResizeGripperRepresentable(
            onBegin: {
                // Always start from the currently displayed (clamped) size so a drag begins
                // at the visible corner even if stored defaults fall outside the bounds.
                (clampedWidth, clampedHeight)
            },
            onDrag: { startW, startH, dx, dy in
                let upperW = min(NotificationsPopoverMetrics.maxWidth, screenMaxWidth)
                let upperH = min(NotificationsPopoverMetrics.maxHeight, screenMaxHeight)
                let newW = min(upperW, max(NotificationsPopoverMetrics.minWidth, startW + dx))
                let newH = min(upperH, max(NotificationsPopoverMetrics.minHeight, startH + dy))
                liveWidth = newW
                liveHeight = newH
            },
            onEnd: {
                // Persist exactly once on mouseUp instead of hammering UserDefaults during drag.
                if let w = liveWidth {
                    savedWidth = Double(w)
                    liveWidth = nil
                }
                if let h = liveHeight {
                    savedHeight = Double(h)
                    liveHeight = nil
                }
            }
        )
        .frame(width: 16, height: 16)
        .accessibilityLabel(Text(String(localized: "notifications.resize", defaultValue: "Resize notifications")))
        .accessibilityHint(Text(String(localized: "notifications.resize.hint", defaultValue: "Drag to resize the notifications popover")))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .cmuxFont(size: 14, weight: .semibold)
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(cmuxAccentColor()))
            }
            Spacer()
            Button(action: jumpToLatestUnread) {
                HStack(spacing: 5) {
                    CmuxSystemSymbolImage(systemName: "arrow.down.to.line", pointSize: 10, weight: .semibold)
                    Text(String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest"))
                        .cmuxFont(size: 11)
                    if !jumpToUnreadShortcut.displayString.isEmpty {
                        Text(jumpToUnreadShortcut.displayString)
                            .cmuxFont(size: 10.5, weight: .medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                            // The button already exposes the shortcut via .accessibilityValue;
                            // hide this visual chip from VoiceOver so it isn't announced twice.
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(hasUnreadNotifications ? 0.12 : 0.05))
            )
            .foregroundColor(hasUnreadNotifications ? .primary : .secondary)
            .accessibilityIdentifier("notificationsPopover.jumpToLatest")
            .accessibilityValue(jumpToUnreadShortcut.displayString)
            .safeHelp(
                KeyboardShortcutSettings.Action.jumpToUnread.tooltip(
                    String(localized: "notifications.jumpToLatest", defaultValue: "Jump to Latest")
                )
            )
            .disabled(!hasUnreadNotifications)

            Button(action: { notificationStore.clearAll() }) {
                Text(String(localized: "notifications.clearAll", defaultValue: "Clear All"))
                    .cmuxFont(size: 11)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(notificationStore.notificationMenuSnapshot.hasNotifications ? 0.12 : 0.05))
            )
            .foregroundColor(notificationStore.notificationMenuSnapshot.hasNotifications ? .primary : .secondary)
            .accessibilityIdentifier("notificationsPopover.clearAll")
            .disabled(notificationStore.notificationMenuSnapshot.hasNotifications == false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !notificationStore.notificationMenuSnapshot.hasNotifications {
            emptyState(
                systemImage: "bell.slash",
                title: String(localized: "notifications.empty.title", defaultValue: "No notifications yet"),
                subtitle: String(localized: "notifications.empty.subtitle", defaultValue: "Desktop notifications will appear here.")
            )
        } else if notificationStore.notifications.isEmpty {
            emptyState(
                systemImage: "bell.badge",
                title: notificationStore.notificationMenuSnapshot.stateHintTitle,
                subtitle: nil
            )
        } else {
            // Snapshot the notifications array as an immutable value before the LazyVStack
            // so the row closures don't reach back into the ObservableObject. Reading the
            // store from inside the ForEach builder reintroduces a store dependency below
            // the list boundary, which is the same anti-pattern CLAUDE.md flags for the
            // sidebar/sessions panel (https://github.com/manaflow-ai/cmux/issues/2586).
            let snapshot = notificationStore.notifications
            let lastIndex = snapshot.count - 1
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(snapshot.enumerated()), id: \.element.id) { index, notification in
                        NotificationPopoverRow(
                            notification: notification,
                            tabTitle: tabTitle(for: notification.tabId),
                            onOpen: { open(notification) },
                            onClear: {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    notificationStore.remove(id: notification.id)
                                }
                            },
                            onToggleRead: {
                                if notification.isRead {
                                    notificationStore.markUnread(id: notification.id)
                                } else {
                                    notificationStore.markRead(id: notification.id)
                                    // A user-initiated "Mark as Read" on a pane-scoped
                                    // notification should also clear the pane's focused-read
                                    // indicator so the pane badge disappears. For
                                    // workspace-level notifications (surfaceId == nil), do not
                                    // call clearFocusedReadIndicator — it treats nil as
                                    // "clear any pane indicator on this tab" and would wipe
                                    // an unrelated pane badge.
                                    if let surfaceId = notification.surfaceId {
                                        notificationStore.clearFocusedReadIndicator(
                                            forTabId: notification.tabId,
                                            surfaceId: surfaceId
                                        )
                                    }
                                }
                            }
                        )
                        if index < lastIndex {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    private func emptyState(systemImage: String, title: String, subtitle: String?) -> some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(systemName: systemImage, pointSize: 30, weight: .light)
                .foregroundColor(.secondary.opacity(0.7))
            Text(title)
                .cmuxFont(size: 14, weight: .medium)
                .foregroundColor(.primary)
            if let subtitle {
                Text(subtitle)
                    .cmuxFont(size: 12)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func tabTitle(for tabId: UUID) -> String? {
        AppDelegate.shared?.tabTitle(for: tabId)
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notificationMenuSnapshot.hasUnreadNotifications
    }

    private var unreadCount: Int {
        notificationStore.notificationMenuSnapshot.unreadCount
    }

    private func jumpToLatestUnread() {
        DispatchQueue.main.async {
            AppDelegate.shared?.jumpToLatestUnread()
            onDismiss()
        }
    }

    private func open(_ notification: TerminalNotification) {
        // SwiftUI action closures are not guaranteed to run on the main actor.
        // Ensure window focus + tab selection happens on the main thread.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.openTerminalNotification(notification)
            onDismiss()
        }
    }
}

private struct NotificationPopoverRow: View {
    let notification: TerminalNotification
    let tabTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void

    @State private var isHovering: Bool = false

    private static let rowHeight: CGFloat = 56

    var body: some View {
        // Row uses a ZStack so the hover-only clear button is a *sibling* of the row's
        // primary-action Button, not nested in its label. Nested SwiftUI buttons don't
        // produce reliable independent hit targets on macOS — clicks on a nested button
        // can be consumed by the outer button's tap area.
        ZStack(alignment: .trailing) {
            // Primary row action wrapped as a Button so the row participates in the
            // key-view loop: keyboard users can tab to a row and activate it with
            // space/return. Visual styling is owned by rowContent; the button background
            // lets the NSTrackingArea-driven hover tint shine through.
            Button(action: onOpen) {
                rowContent
                    .background(
                        Color.primary.opacity(isHovering ? 0.11 : 0)
                    )
            }
            .buttonStyle(.plain)
            // Identifier/action live on the Button itself so XCUITest's
            // `app.buttons["NotificationPopoverRow.<id>"]` query keeps matching. A previous
            // pass put them on the combined outer ZStack, which exposed the row as a
            // container rather than a button to accessibility clients.
            .accessibilityIdentifier("NotificationPopoverRow.\(notification.id.uuidString)")
            // XCUITest's `.click()` isn't always reliable for SwiftUI buttons hosted in an
            // `NSPopover`. Provide an explicit accessibility action so AXPress always routes to onOpen.
            .accessibilityAction { onOpen() }
            // The clear button is hover-only for pointer users; expose dismiss as a row-level
            // accessibility action so VoiceOver / keyboard / assistive tech can dismiss too.
            .accessibilityAction(
                named: Text(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
            ) {
                onClear()
            }

            clearButton
                .padding(.trailing, 10)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                // Dismissal is exposed through the row Button's accessibility action and the
                // context menu, so hide this hover-only affordance from keyboard focus /
                // VoiceOver when not visible — otherwise Full Keyboard Access can tab to an
                // invisible button.
                .accessibilityHidden(!isHovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Hover detection runs through an AppKit NSTrackingArea (HoverTrackingRepresentable)
        // because SwiftUI's `.onHover` / `.onContinuousHover` arbitrate with the row's
        // primary action and miss enter/exit events right after the popover opens and when
        // the pointer crosses between LazyVStack rows.
        .background(
            HoverTrackingRepresentable { hovering in
                if isHovering != hovering { isHovering = hovering }
            }
        )
        .contextMenu {
                Button(String(localized: "notifications.open", defaultValue: "Open")) {
                    onOpen()
                }
                if notification.isRead {
                    Button(String(localized: "notifications.markAsUnread", defaultValue: "Mark as Unread")) {
                        onToggleRead()
                    }
                } else {
                    Button(String(localized: "notifications.markAsRead", defaultValue: "Mark as Read")) {
                        onToggleRead()
                    }
                }
                Divider()
                Button(String(localized: "notifications.dismiss", defaultValue: "Dismiss"), role: .destructive) {
                    onClear()
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(notification.isRead ? Color.clear : cmuxAccentColor())
                .frame(width: 2.5)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.title)
                        .cmuxFont(size: 12.5, weight: .semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                        .cmuxFont(size: 10.5)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 34)
                }

                if !notification.body.isEmpty {
                    Text(notification.body)
                        .cmuxFont(size: 11.5)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let tabTitle, !tabTitle.isEmpty {
                    Text(tabTitle)
                        .cmuxFont(size: 10)
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .frame(minHeight: Self.rowHeight)
        .padding(.leading, 4)
    }

    private var clearButton: some View {
        Button(action: onClear) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.1))
                CmuxSystemSymbolImage(systemName: "xmark", pointSize: 9, weight: .bold)
                    .foregroundColor(.primary.opacity(0.7))
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
    }
}

private struct ResizeGripperRepresentable: NSViewRepresentable {
    let onBegin: () -> (CGFloat, CGFloat)
    let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    func updateNSView(_ nsView: ResizeGripperNSView, context: Context) {
        nsView.onBegin = onBegin
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class ResizeGripperNSView: NSView {
    var onBegin: () -> (CGFloat, CGFloat) = { (0, 0) }
    var onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void = { _, _, _, _ in }
    var onEnd: () -> Void = {}

    private var pressLocation: NSPoint?
    private var pressStartWidth: CGFloat = 0
    private var pressStartHeight: CGFloat = 0

    private static let diagonalResizeCursor: NSCursor = {
        // AppKit ships a NW–SE diagonal resize cursor for window corners but doesn't expose
        // it publicly. It has lived under this selector for years and is widely used by Mac
        // apps that need a diagonal resize affordance.
        let selector = NSSelectorFromString("_windowResizeNorthWestSouthEastCursor")
        if let method = NSCursor.responds(to: selector) ? NSCursor.perform(selector) : nil,
           let cursor = method.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return NSCursor.crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.diagonalResizeCursor)
    }

    override func mouseDown(with event: NSEvent) {
        // NSEvent.mouseLocation is screen-coordinate and stable while the popover resizes.
        pressLocation = NSEvent.mouseLocation
        let (w, h) = onBegin()
        pressStartWidth = w
        pressStartHeight = h
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        // Screen-y grows upward; popover should grow as the pointer moves down (toward
        // smaller screen-y), so invert.
        let dy = start.y - current.y
        onDrag(pressStartWidth, pressStartHeight, dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
        onEnd()
    }
}

private struct HoverTrackingRepresentable: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class HoverTrackingNSView: NSView {
    var onChange: (Bool) -> Void
    private var trackingArea: NSTrackingArea?
    private var isInside: Bool = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass clicks through to the SwiftUI parent (which owns the tap gesture and accessibility
    // action). Tracking areas keep working because they're driven by window mouse-tracking,
    // not by hitTest.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area

        // Sync current pointer state in case the pointer is already inside when the tracking
        // area is (re)installed — happens on first popover open or after layout changes.
        // updateTrackingAreas runs on the main thread, so dispatch synchronously; deferring
        // creates a race where mouseExited can fire before the queued sync-onChange(true) runs,
        // leaving the row stuck in the hovered state.
        if let window, window.isVisible {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let nowInside = bounds.contains(mouseInView)
            if nowInside != isInside {
                isInside = nowInside
                onChange(nowInside)
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !isInside {
            isInside = true
            onChange(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isInside {
            isInside = false
            onChange(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isInside {
            isInside = false
            onChange(false)
        }
    }
}

@MainActor
final class UpdateTitlebarAccessoryController {
    private let updateLog: UpdateLogStore
    private let settingsRuntime: SettingsRuntime?
    private var didStart = false
    private let attachedWindows = NSHashTable<NSWindow>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private var pendingAttachRetries: [ObjectIdentifier: Int] = [:]
    private var startupScanWorkItems: [DispatchWorkItem] = []
    private let controlsIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
    private let controlsControllers = NSHashTable<TitlebarControlsAccessoryViewController>.weakObjects()
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()
    private var detachedNotificationsPopover: NSPopover?
    private var detachedNotificationsPopoverDelegate: DetachedNotificationsPopoverDelegate?

    init(updateLog: UpdateLogStore, settingsRuntime: SettingsRuntime?) {
        self.updateLog = updateLog
        self.settingsRuntime = settingsRuntime
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
        scheduleStartupWindowScans()
    }

    func attach(to window: NSWindow) {
        attachIfNeeded(to: window)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.attachIfNeeded(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.attachIfNeeded(to: window)
            }
        })

        // Re-evaluate all windows when the presentation mode changes so that
        // accessories are removed in minimal mode and re-attached in standard mode.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reattachIfPresentationModeChanged()
            }
        })

        // We intentionally do not rely on "window became visible" notifications here:
        // AppKit does not provide a stable cross-SDK API for this. Startup scans handle this case.
    }

    private func reattachIfPresentationModeChanged() {

        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode

        if currentMode == .standard {
            attachToExistingWindows()
        }
        for window in attachedWindows.allObjects {
            applyAccessoryVisibility(for: window)
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachIfNeeded(to: window)
        }
    }

    private func scheduleStartupWindowScans() {
        // We want to be robust to SwiftUI/AppKit timing and to XCTest automation. Scanning
        // NSApp.windows briefly at startup is cheap and ensures accessories are attached even
        // if key/main/visible notifications are missed.
        let delays: [TimeInterval] = [0.05, 0.15, 0.3, 0.6, 1.0, 2.0, 3.0]
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.attachToExistingWindows()
                }
#if DEBUG
                let env = ProcessInfo.processInfo.environment
                if env["CMUX_UI_TEST_MODE"] == "1" {
                    let ids = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                    let delayText = String(format: "%.2f", delay)
                    self?.updateLog.append("startup window scan (delay=\(delayText)) count=\(NSApp.windows.count) ids=\(ids.joined(separator: ","))")
                }
#endif
            }
            startupScanWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func attachIfNeeded(to window: NSWindow) {
        guard NSApp.windows.contains(where: { $0 === window }) else {
            pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
            return
        }
        guard !isSettingsWindow(window) else { return }

        // Window identifiers are assigned by SwiftUI via WindowAccessor, which can run
        // after didBecomeKey/didBecomeMain notifications. Retry briefly to avoid missing
        // attaching accessories (notably in UI tests).
        if !isMainTerminalWindow(window) {
            let key = ObjectIdentifier(window)
            let attempts = pendingAttachRetries[key, default: 0]
            if attempts < 40 {
                pendingAttachRetries[key] = attempts + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window else { return }
                        self.attachIfNeeded(to: window)
                    }
                }
            } else {
                pendingAttachRetries.removeValue(forKey: key)
            }
            return
        }

        pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
        guard canAccessTitlebarAccessories(on: window) else { return }

        // Don't re-attach controls if already attached.
        guard !attachedWindows.contains(window) else {
            applyAccessoryVisibility(for: window)
            return
        }

        if !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == controlsIdentifier }) {
            let controls = TitlebarControlsAccessoryViewController(
                notificationStore: TerminalNotificationStore.shared,
                settingsRuntime: settingsRuntime
            )
            controls.layoutAttribute = .left
            controls.view.identifier = controlsIdentifier
            window.addTitlebarAccessoryViewController(controls)
            controlsControllers.add(controls)
        }

        attachedWindows.add(window)
        applyAccessoryVisibility(for: window)

#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let ident = window.identifier?.rawValue ?? "<nil>"
            updateLog.append("attached titlebar accessories to window id=\(ident)")
        }
#endif
    }

    private func applyAccessoryVisibility(for window: NSWindow) {
        guard canAccessTitlebarAccessories(on: window) else {
            attachedWindows.remove(window)
            pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
            return
        }
        let shouldHide = WorkspacePresentationModeSettings.mode() == .minimal
            || window.styleMask.contains(.fullScreen)
        for accessory in window.titlebarAccessoryViewControllers
            where accessory.view.identifier == controlsIdentifier {
            accessory.isHidden = shouldHide
            accessory.view.isHidden = shouldHide
            accessory.view.alphaValue = shouldHide ? 0 : 1
        }
    }

    private func removeAccessoryIfPresent(from window: NSWindow) {
        guard canAccessTitlebarAccessories(on: window) else {
            attachedWindows.remove(window)
            pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
            return
        }
        let matchingIndices = window.titlebarAccessoryViewControllers.indices.reversed().filter { index in
            let id = window.titlebarAccessoryViewControllers[index].view.identifier
            return id == controlsIdentifier
        }
        guard !matchingIndices.isEmpty || attachedWindows.contains(window) else { return }

        for index in matchingIndices {
            let accessory = window.titlebarAccessoryViewControllers[index]
            if let controls = accessory as? TitlebarControlsAccessoryViewController {
                controls.dismissNotificationsPopover()
            }
            window.removeTitlebarAccessoryViewController(at: index)
        }

        attachedWindows.remove(window)
        pendingAttachRetries.removeValue(forKey: ObjectIdentifier(window))
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.contentView?.needsLayout = true
            window.contentView?.superview?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.invalidateShadow()
        }

#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let ident = window.identifier?.rawValue ?? "<nil>"
            updateLog.append("removed titlebar accessories from window id=\(ident)")
        }
#endif
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == "cmux.settings" {
            return true
        }
        return window.title == "Settings"
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func canAccessTitlebarAccessories(on window: NSWindow) -> Bool {
        isMainTerminalWindow(window) && window.styleMask.contains(.titled) && !isSettingsWindow(window)
    }

    private func preferredNotificationsController(
        from controllers: [TitlebarControlsAccessoryViewController],
        preferShownPopover: Bool
    ) -> TitlebarControlsAccessoryViewController? {
        if let keyWindow = NSApp.keyWindow,
           let match = controllers.first(where: { $0.view.window === keyWindow }) {
            return match
        }
        if let keyMain = NSApp.windows.first(where: { $0.isKeyWindow && isMainTerminalWindow($0) }),
           let match = controllers.first(where: { $0.view.window === keyMain }) {
            return match
        }
        if preferShownPopover,
           let shown = controllers.first(where: { $0.popoverIsShownForTesting }) {
            return shown
        }
        return controllers.first
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        let controllers = controlsControllers.allObjects

        // If an external anchor is provided (e.g. fullscreen sidebar controls),
        // use it for popover positioning instead of the hidden titlebar accessory.
        if let anchorView, anchorView.window != nil {
            let target = preferredNotificationsController(from: controllers, preferShownPopover: true)
            guard let target else {
                toggleDetachedNotificationsPopover(animated: animated, anchorView: anchorView)
                return
            }
            for controller in controllers where controller !== target {
                controller.dismissNotificationsPopover()
            }
            target.toggleNotificationsPopover(animated: animated, externalAnchor: anchorView)
            return
        }

        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: true)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        target?.toggleNotificationsPopover(animated: animated)
    }

    private func toggleDetachedNotificationsPopover(animated: Bool, anchorView: NSView) {
        if let popover = detachedNotificationsPopover, popover.isShown {
            popover.animates = animated
            popover.performClose(nil)
            return
        }
        guard let window = anchorView.window,
              let contentView = window.contentView else {
            return
        }

        let popover = NSPopover()
        let delegate = DetachedNotificationsPopoverDelegate { [weak self, weak popover] in
            popover?.contentViewController = nil
            guard let self, self.detachedNotificationsPopover === popover else { return }
            self.detachedNotificationsPopover = nil
            self.detachedNotificationsPopoverDelegate = nil
            if let popover {
                postNotificationsPopoverVisibilityDidChange(isShown: false, source: popover)
            } else {
                postNotificationsPopoverVisibilityDidChange(isShown: false)
            }
        }
        popover.behavior = .semitransient
        popover.animates = animated
        popover.delegate = delegate
        popover.contentViewController = NSHostingController(
            rootView: NotificationsPopoverView(
                notificationStore: TerminalNotificationStore.shared,
                onDismiss: { [weak popover] in
                    popover?.performClose(nil)
                }
            )
        )

        contentView.layoutSubtreeIfNeeded()
        anchorView.superview?.layoutSubtreeIfNeeded()
        let anchorRect = anchorView.convert(anchorView.bounds, to: contentView)
        guard !anchorRect.isEmpty else { return }

        detachedNotificationsPopover = popover
        detachedNotificationsPopoverDelegate = delegate
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
        postNotificationsPopoverVisibilityDidChange(
            isShown: true,
            source: popover,
            windowNumber: window.windowNumber
        )
    }

    func isNotificationsPopoverShown() -> Bool {
        detachedNotificationsPopover?.isShown == true ||
            controlsControllers.allObjects.contains(where: { $0.popoverIsShownForTesting })
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        let controllers = controlsControllers.allObjects
        var dismissed = false
        if let popover = detachedNotificationsPopover, popover.isShown {
            popover.performClose(nil)
            dismissed = true
        }
        for controller in controllers where controller.popoverIsShownForTesting {
            controller.dismissNotificationsPopover()
            dismissed = true
        }
        return dismissed
    }

    func showNotificationsPopover(animated: Bool = true) {
        let controllers = controlsControllers.allObjects
        guard !controllers.isEmpty else { return }

        let target = preferredNotificationsController(from: controllers, preferShownPopover: false)
        for controller in controllers {
            if controller !== target {
                controller.dismissNotificationsPopover()
            }
        }
        guard let target else { return }
        if target.popoverIsShownForTesting {
            return
        }
        target.toggleNotificationsPopover(animated: animated)
    }
}
