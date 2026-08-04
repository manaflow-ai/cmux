import AppKit
import Bonsplit
import Combine
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxTestSupport
import Observation

struct TitlebarEdgeInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0
}

enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    static let storageKey = "titlebarControlsStyle"
    static let defaultStyle = TitlebarControlsStyle.classic
    static var defaultRawValue: Int { defaultStyle.rawValue }

    var id: Int { rawValue }

    static func stored(in defaults: UserDefaults = .standard) -> TitlebarControlsStyle {
        guard let rawObject = defaults.object(forKey: storageKey) else {
            return defaultStyle
        }
        let rawValue: Int?
        if let integer = rawObject as? Int {
            rawValue = integer
        } else if let number = rawObject as? NSNumber {
            rawValue = number.intValue
        } else {
            rawValue = nil
        }
        guard let rawValue else { return defaultStyle }
        return TitlebarControlsStyle(rawValue: rawValue) ?? defaultStyle
    }

    static func stored(rawValue: Int) -> TitlebarControlsStyle {
        TitlebarControlsStyle(rawValue: rawValue) ?? defaultStyle
    }

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
                groupPadding: TitlebarEdgeInsets(),
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
                groupPadding: TitlebarEdgeInsets(),
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
                groupPadding: TitlebarEdgeInsets(),
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
                groupPadding: TitlebarEdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3),
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
                groupPadding: TitlebarEdgeInsets(),
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
    let groupPadding: TitlebarEdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

struct TitlebarControlsLayoutModelSnapshot: Equatable {
    let style: TitlebarControlsStyle
    let contentSize: NSSize
}

/// Owns the expensive shortcut/font-derived titlebar size once for every
/// titlebar surface. Unrelated defaults and notification activity must not
/// invalidate titlebar geometry.
@MainActor
@Observable
final class TitlebarControlsLayoutModel {
    typealias ContentSizeProvider = (TitlebarControlsStyleConfig) -> NSSize

    private(set) var snapshot: TitlebarControlsLayoutModelSnapshot

    private let defaults: UserDefaults
    @ObservationIgnored
    private let notificationCenter: NotificationCenter
    private let contentSizeProvider: ContentSizeProvider
    @ObservationIgnored
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        contentSizeProvider: @escaping ContentSizeProvider = {
            TitlebarControlsLayoutMetrics.contentSize(config: $0)
        }
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.contentSizeProvider = contentSizeProvider
        let style = TitlebarControlsStyle.stored(in: defaults)
        snapshot = TitlebarControlsLayoutModelSnapshot(
            style: style,
            contentSize: contentSizeProvider(style.config)
        )

        observers.append(
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshStyleIfNeeded()
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: KeyboardShortcutSettings.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.shortcutChangeAffectsLayout(notification) else { return }
                    self.recompute()
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: GlobalFontMagnification.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recompute()
                }
            }
        )
    }

    deinit {
        removeObservers()
    }

    private nonisolated func removeObservers() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func refreshStyleIfNeeded() {
        let style = TitlebarControlsStyle.stored(in: defaults)
        guard style != snapshot.style else { return }
        recompute(style: style)
    }

    private func shortcutChangeAffectsLayout(_ notification: Notification) -> Bool {
        guard let rawAction = notification.userInfo?[KeyboardShortcutSettings.actionUserInfoKey]
            as? String,
              let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
            // Bulk and settings-file reloads intentionally omit one action.
            return true
        }
        return TitlebarShortcutHintActionSlot.allCases.contains { $0.action == action }
    }

    private func recompute(style: TitlebarControlsStyle? = nil) {
        let style = style ?? snapshot.style
        snapshot = TitlebarControlsLayoutModelSnapshot(
            style: style,
            contentSize: contentSizeProvider(style.config)
        )
    }
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
        guard let action = slot.action else { continue }
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
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

    var action: KeyboardShortcutSettings.Action? {
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
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        guard let first = ranges.first, let last = ranges.last else { return 0 }
        return last.upperBound - first.lowerBound
    }

    static func buttonCenterX(
        for slot: TitlebarShortcutHintActionSlot,
        config: TitlebarControlsStyleConfig
    ) -> CGFloat {
        let actionSlot: MinimalModeSidebarControlActionSlot = switch slot {
        case .toggleSidebar:
            .toggleSidebar
        case .showNotifications:
            .showNotifications
        case .newTab:
            .newTab
        case .focusHistoryBack:
            .focusHistoryBack
        case .focusHistoryForward:
            .focusHistoryForward
        }
        guard let range = TitlebarControlsHitRegions.buttonXRange(for: actionSlot, config: config) else {
            return config.groupPadding.leading + (config.buttonSize / 2.0)
        }
        return (range.lowerBound + range.upperBound) / 2.0
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

private enum TitlebarHeaderChromeIconStyle {
    static let opacity = 0.86
    static let hoveredOpacity = 0.96
    static let pressedOpacity = 1.0
    static let disabledOpacity = 0.34
    static let weight: NSFont.Weight = .regular
    static let foregroundColor = NSColor.secondaryLabelColor
    static let sidebarGlyphStrokeWidth: CGFloat = 1

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    static func foregroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed { return pressedOpacity }
        if isHovering { return hoveredOpacity }
        return opacity
    }

    static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed { return 0.14 }
        if isHovering { return hoverBackground ? 0.09 : 0.07 }
        return 0
    }

    static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed { return 0.11 }
        if isHovering { return 0.07 }
        return buttonBackground ? 0.05 : 0
    }
}

private enum TitlebarControlIconStyle {
    static let opacity = TitlebarHeaderChromeIconStyle.opacity
    static let hoveredOpacity = TitlebarHeaderChromeIconStyle.hoveredOpacity
    static let pressedOpacity = TitlebarHeaderChromeIconStyle.pressedOpacity
    static let weight = TitlebarHeaderChromeIconStyle.weight
    static let foregroundColor = TitlebarHeaderChromeIconStyle.foregroundColor
    static let sidebarGlyphStrokeWidth = TitlebarHeaderChromeIconStyle.sidebarGlyphStrokeWidth

    static func iconFrameSize(for config: TitlebarControlsStyleConfig) -> CGFloat {
        TitlebarHeaderChromeIconStyle.iconFrameSize(forIconSize: config.iconSize)
    }
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool) -> Double {
    titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool) -> Double {
    TitlebarHeaderChromeIconStyle.foregroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled)
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
    TitlebarHeaderChromeIconStyle.backgroundOpacity(
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
    TitlebarHeaderChromeIconStyle.borderOpacity(
        buttonBackground: config.buttonBackground,
        isHovering: isHovering,
        isPressed: isPressed,
        isEnabled: isEnabled
    )
}

func titlebarControlActiveHoverBackgroundOpacity(
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    guard isEnabled, isHovering, !isPressed else { return 0 }
    return 0.09
}

func titlebarControlPassiveHoverBackgroundOpacity(
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    guard isEnabled, isHovering, !isPressed else { return 0 }
    return 0.016
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
func focusHistoryNavigationAvailability(
    preferredWindow: NSWindow?
) -> FocusHistoryNavigationAvailability {
    guard let manager = AppDelegate.shared?.activeTabManagerForCommands(
        preferredWindow: preferredWindow
    ) else {
        return .unavailable
    }
    return FocusHistoryNavigationAvailability(
        canNavigateBack: manager.canNavigateBack,
        canNavigateForward: manager.canNavigateForward
    )
}

@MainActor
private final class TitlebarNotificationBadgeNativeView: NSView {
    var count = 0 {
        didSet {
            isHidden = count <= 0
            needsDisplay = true
        }
    }
    var config = TitlebarControlsStyle.classic.config {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: config.badgeSize, height: config.badgeSize)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        cmuxAccentNSColor().setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let text = String(min(count, 99))
        let font = NSFont.systemFont(
            ofSize: GlobalFontMagnification.scaledSize(titlebarNotificationBadgeFontSize(for: config)),
            weight: .semibold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

@MainActor
final class TitlebarControlsView: NSView {
    let unreadModel: SidebarUnreadModel
    let layoutModel: TitlebarControlsLayoutModel
    let viewModel: TitlebarControlsViewModel
    var onToggleSidebar: () -> Void
    var onToggleNotifications: () -> Void
    var onNewTab: () -> Void
    var onFocusHistoryBack: () -> Void
    var onFocusHistoryForward: () -> Void
    var visibilityMode: TitlebarControlsVisibilityMode

    private let sidebarButton = TitlebarNativeButton(symbolName: "sidebar.left")
    private let notificationsButton = TitlebarNativeButton(symbolName: "bell")
    private let splitButton: TitlebarNewWorkspaceCloudSplitButton
    private let backButton = TitlebarNativeButton(symbolName: "arrow.left")
    private let forwardButton = TitlebarNativeButton(symbolName: "arrow.right")
    private let badgeView = TitlebarNotificationBadgeNativeView()
    private let modifierKeyMonitor = WindowScopedShortcutHintModifierMonitor(activation: .commandOnly)
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings().alwaysShowHints
    private var shortcutHintViews: [KeyboardShortcutSettings.Action: SidebarShortcutHintPillView] = [:]
    private var unreadObservation: SidebarUnreadObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var trackingAreaReference: NSTrackingArea?
    private var hostWindowNumber: Int?
    private var isHoveringControls = false
    private var layoutObservationGeneration: UInt64 = 0
    private var modifierObservationGeneration: UInt64 = 0

    init(
        unreadModel: SidebarUnreadModel,
        layoutModel: TitlebarControlsLayoutModel,
        viewModel: TitlebarControlsViewModel,
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void,
        visibilityMode: TitlebarControlsVisibilityMode
    ) {
        self.unreadModel = unreadModel
        self.layoutModel = layoutModel
        self.viewModel = viewModel
        self.onToggleSidebar = onToggleSidebar
        self.onToggleNotifications = onToggleNotifications
        self.onNewTab = onNewTab
        self.onFocusHistoryBack = onFocusHistoryBack
        self.onFocusHistoryForward = onFocusHistoryForward
        self.visibilityMode = visibilityMode
        splitButton = TitlebarNewWorkspaceCloudSplitButton(
            config: layoutModel.snapshot.style.config,
            onNewTab: onNewTab
        )
        super.init(frame: NSRect(origin: .zero, size: layoutModel.snapshot.contentSize))

        wantsLayer = true
        clipsToBounds = false
        for control in [sidebarButton, notificationsButton, splitButton, backButton, forwardButton] {
            addSubview(control)
        }
        addSubview(badgeView)

        configureButtons()
        observeModels()
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            unreadObservation?.cancel()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        layoutModel.snapshot.contentSize
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostWindowNumber = window?.windowNumber
        let hintsEnabled = ShortcutHintDebugSettings().modifierHoldHintsEnabled
        modifierKeyMonitor.setHostWindow(hintsEnabled ? window : nil)
        if hintsEnabled {
            modifierKeyMonitor.start()
        } else {
            modifierKeyMonitor.stop()
        }
        if let window {
            NotificationsAnchorRegistry.shared.register(notificationsButton)
            viewModel.notificationsAnchorView = notificationsButton
            TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: window)
        } else {
            modifierKeyMonitor.stop()
            hostWindowNumber = nil
        }
        refreshAll()
    }

    override func layout() {
        super.layout()
        let config = layoutModel.snapshot.style.config
        let y = max(0, (bounds.height - config.buttonSize) / 2)
        setFrame(sidebarButton, slot: .toggleSidebar, y: y, config: config)
        setFrame(notificationsButton, slot: .showNotifications, y: y, config: config)

        if let primary = TitlebarControlsHitRegions.buttonXRange(for: .newTab, config: config),
           let menu = TitlebarControlsHitRegions.buttonXRange(for: .cloudVM, config: config) {
            splitButton.frame = NSRect(
                x: primary.lowerBound,
                y: y,
                width: menu.upperBound - primary.lowerBound,
                height: config.buttonSize
            )
        }

        setFrame(backButton, slot: .focusHistoryBack, y: y, config: config)
        setFrame(forwardButton, slot: .focusHistoryForward, y: y, config: config)
        badgeView.frame = NSRect(
            x: notificationsButton.frame.maxX - config.badgeSize + config.badgeOffset.width,
            y: notificationsButton.frame.maxY - config.badgeSize - config.badgeOffset.height,
            width: config.badgeSize,
            height: config.badgeSize
        )
        layoutShortcutHints(config: config)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingAreaReference = next
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringControls = true
        refreshVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringControls = false
        refreshVisibility(animated: true)
    }

    func update(
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping () -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void,
        visibilityMode: TitlebarControlsVisibilityMode
    ) {
        self.onToggleSidebar = onToggleSidebar
        self.onToggleNotifications = onToggleNotifications
        self.onNewTab = onNewTab
        self.onFocusHistoryBack = onFocusHistoryBack
        self.onFocusHistoryForward = onFocusHistoryForward
        self.visibilityMode = visibilityMode
        splitButton.onNewTab = onNewTab
        refreshAll()
    }

    private func configureButtons() {
        configure(
            sidebarButton,
            identifier: "titlebarControl.toggleSidebar",
            label: String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"),
            tooltip: KeyboardShortcutSettings.Action.toggleSidebar.tooltip(
                String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")
            ),
            action: #selector(toggleSidebar(_:))
        )
        sidebarButton.onRightMouseDown = { anchorView, event in
            CmuxExtensionSidebarSelection.showMenu(anchorView: anchorView, event: event)
        }

        configure(
            notificationsButton,
            identifier: "titlebarControl.showNotifications",
            label: String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"),
            tooltip: KeyboardShortcutSettings.Action.showNotifications.tooltip(
                String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")
            ),
            action: #selector(toggleNotifications(_:))
        )

        configure(
            backButton,
            identifier: "titlebarControl.focusHistoryBack",
            label: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"),
            tooltip: KeyboardShortcutSettings.Action.focusHistoryBack.tooltip(
                String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
            ),
            action: #selector(navigateBack(_:))
        )
        backButton.onRightMouseDown = { anchorView, event in
            _ = AppDelegate.shared?.showFocusHistoryContextMenu(
                anchorView: anchorView,
                event: event,
                direction: .back
            )
        }

        configure(
            forwardButton,
            identifier: "titlebarControl.focusHistoryForward",
            label: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"),
            tooltip: KeyboardShortcutSettings.Action.focusHistoryForward.tooltip(
                String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
            ),
            action: #selector(navigateForward(_:))
        )
        forwardButton.onRightMouseDown = { anchorView, event in
            _ = AppDelegate.shared?.showFocusHistoryContextMenu(
                anchorView: anchorView,
                event: event,
                direction: .forward
            )
        }
    }

    private func configure(
        _ button: TitlebarNativeButton,
        identifier: String,
        label: String,
        tooltip: String,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(label)
        button.toolTip = tooltip
    }

    private func observeModels() {
        unreadObservation = unreadModel.observeChanges(owner: self) { owner, snapshot in
            owner.badgeView.count = snapshot.totalUnreadCount
            owner.needsLayout = true
        }

        NotificationsPopoverVisibilityState.shared.$shownWindowNumbers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisibility(animated: true)
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .tabManagerFocusHistoryRevisionDidChange,
            NSWindow.didBecomeKeyNotification,
            .ghosttyConfigDidReload,
            .ghosttyDefaultBackgroundDidChange,
            UserDefaults.didChangeNotification,
            KeyboardShortcutSettings.didChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshAll()
                }
            })
        }

        observeLayoutModel()
        observeModifierState()
    }

    private func observeLayoutModel() {
        layoutObservationGeneration &+= 1
        let generation = layoutObservationGeneration
        withObservationTracking {
            _ = layoutModel.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.layoutObservationGeneration else { return }
                self.refreshAll()
                self.observeLayoutModel()
            }
        }
    }

    private func observeModifierState() {
        modifierObservationGeneration &+= 1
        let generation = modifierObservationGeneration
        withObservationTracking {
            _ = modifierKeyMonitor.isModifierPressed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.modifierObservationGeneration else { return }
                self.refreshShortcutHints()
                self.refreshVisibility(animated: true)
                self.observeModifierState()
            }
        }
    }

    private func refreshAll() {
        let snapshot = layoutModel.snapshot
        let config = snapshot.style.config
        frame.size = snapshot.contentSize
        for button in [sidebarButton, notificationsButton, backButton, forwardButton] {
            button.config = config
        }
        splitButton.update(
            config: config,
            foregroundColor: titlebarControlForegroundNSColor(opacity: 1),
            onNewTab: onNewTab
        )
        badgeView.config = config
        badgeView.count = unreadModel.totalUnreadCount

        let availability = focusHistoryNavigationAvailability(preferredWindow: focusHistoryTargetWindow)
        backButton.isEnabled = availability.canNavigateBack
        forwardButton.isEnabled = availability.canNavigateForward

        let hintsEnabled = ShortcutHintDebugSettings().modifierHoldHintsEnabled
        modifierKeyMonitor.setHostWindow(hintsEnabled ? window : nil)
        if hintsEnabled && window != nil {
            modifierKeyMonitor.start()
        } else {
            modifierKeyMonitor.stop()
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        refreshShortcutHints()
        refreshVisibility(animated: false)
    }

    private var focusHistoryTargetWindow: NSWindow? {
        if let hostWindowNumber,
           let hostWindow = NSApp.windows.first(where: { $0.windowNumber == hostWindowNumber }) {
            return hostWindow
        }
        return window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private var shouldShowTitlebarShortcutHints: Bool {
        alwaysShowShortcutHints
            || (ShortcutHintDebugSettings().modifierHoldHintsEnabled && modifierKeyMonitor.isModifierPressed)
    }

    private func refreshShortcutHints() {
        let config = layoutModel.snapshot.style.config
        var visibleActions: Set<KeyboardShortcutSettings.Action> = []
        let xOffset = CGFloat(
            ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultTitlebarHintX)
        )

        if shouldShowTitlebarShortcutHints {
            for slot in TitlebarShortcutHintActionSlot.allCases {
                guard let action = slot.action else { continue }
                let shortcut = KeyboardShortcutSettings.shortcut(for: action)
                guard ShortcutHintTitlebarPolicy.shouldShow(
                    shortcut: shortcut,
                    alwaysShowShortcutHints: alwaysShowShortcutHints,
                    modifierPressed: modifierKeyMonitor.isModifierPressed,
                    modifierHoldHintsEnabled: ShortcutHintDebugSettings().modifierHoldHintsEnabled
                ) else { continue }

                visibleActions.insert(action)
                let pill = shortcutHintViews[action] ?? {
                    let view = SidebarShortcutHintPillView()
                    view.setAccessibilityIdentifier("titlebarShortcutHint.\(action.rawValue)")
                    view.setAccessibilityElement(false)
                    addSubview(view)
                    shortcutHintViews[action] = view
                    return view
                }()
                pill.configure(
                    text: shortcut.displayString,
                    fontSize: max(8, config.iconSize - 5),
                    emphasis: 1
                )
                let width = titlebarHintPillWidth(for: shortcut, config: config)
                let interval = TitlebarControlsLayoutMetrics.hintInterval(
                    for: slot,
                    width: width,
                    config: config,
                    xOffset: xOffset
                )
                pill.frame.size = NSSize(width: width, height: titlebarShortcutHintHeight(for: config))
                pill.frame.origin.x = (interval.lowerBound + interval.upperBound - width) / 2
            }
        }

        for (action, pill) in shortcutHintViews where !visibleActions.contains(action) {
            pill.configure(text: nil, fontSize: max(8, config.iconSize - 5), emphasis: 1)
        }
        needsLayout = true
    }

    private func layoutShortcutHints(config: TitlebarControlsStyleConfig) {
        let yFromTop = config.groupPadding.top
            + titlebarShortcutHintVerticalOffset(for: config)
            + CGFloat(ShortcutHintDebugSettings.clamped(ShortcutHintDebugSettings.defaultTitlebarHintY))
        for pill in shortcutHintViews.values where !pill.isHidden {
            pill.frame.origin.y = bounds.height - yFromTop - pill.frame.height
        }
    }

    private func refreshVisibility(animated: Bool) {
        let shouldShow = visibilityMode == .alwaysVisible
            || isHoveringControls
            || NotificationsPopoverVisibilityState.shared.isShown(in: hostWindowNumber)
            || shouldShowTitlebarShortcutHints
        let target: CGFloat = shouldShow ? 1 : 0
        guard alphaValue != target || isHidden == shouldShow else { return }

        isHidden = false
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.14
                animator().alphaValue = target
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, target == 0, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            })
        } else {
            alphaValue = target
            isHidden = !shouldShow
        }
    }

    private func setFrame(
        _ view: NSView,
        slot: MinimalModeSidebarControlActionSlot,
        y: CGFloat,
        config: TitlebarControlsStyleConfig
    ) {
        guard let range = TitlebarControlsHitRegions.buttonXRange(for: slot, config: config) else {
            view.frame = .zero
            return
        }
        view.frame = NSRect(
            x: range.lowerBound,
            y: y,
            width: range.upperBound - range.lowerBound,
            height: config.buttonSize
        )
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        #if DEBUG
        cmuxDebugLog("titlebar.toggleSidebar")
        #endif
        onToggleSidebar()
    }

    @objc private func toggleNotifications(_ sender: Any?) {
        #if DEBUG
        cmuxDebugLog("titlebar.notifications")
        #endif
        onToggleNotifications()
    }

    @objc private func navigateBack(_ sender: Any?) {
        onFocusHistoryBack()
    }

    @objc private func navigateForward(_ sender: Any?) {
        onFocusHistoryForward()
    }
}

@MainActor
private final class TitlebarControlsGapDragNativeView: NSView {
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
        if event.clickCount >= 2, performStandardTitlebarDoubleClick(window: window) != nil {
            return
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

@MainActor
private final class MinimalModeTitlebarButtonHitRegionNativeView:
    NSView,
    MinimalModeSidebarControlActionHitRegionProviding
{
    nonisolated(unsafe) var config = TitlebarControlsStyle.classic.config

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
        } else {
            MinimalModeTitlebarControlHitRegionRegistry.register(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
        minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
    }

    nonisolated func minimalModeSidebarControlActionSlot(
        localPoint: NSPoint
    ) -> MinimalModeSidebarControlActionSlot? {
        TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config)
    }

    deinit {
        MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
    }
}

@MainActor
final class HiddenTitlebarSidebarControlsView: NSView {
    private let layoutModel: TitlebarControlsLayoutModel
    private let controlsViewModel = TitlebarControlsViewModel()
    private let controls: TitlebarControlsView
    private let gapDragView = TitlebarControlsGapDragNativeView()
    private let hitRegionView = MinimalModeTitlebarButtonHitRegionNativeView()
    private let hoverTrackingView = PassthroughHoverTrackingNativeView()
    private var cancellables: Set<AnyCancellable> = []
    private var isHoveringHost = false
    private var isHoveringWindowChrome = false

    init(
        unreadModel: SidebarUnreadModel,
        layoutModel: TitlebarControlsLayoutModel,
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping (NSView?) -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void
    ) {
        self.layoutModel = layoutModel
        controls = TitlebarControlsView(
            unreadModel: unreadModel,
            layoutModel: layoutModel,
            viewModel: controlsViewModel,
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: {},
            onNewTab: onNewTab,
            onFocusHistoryBack: onFocusHistoryBack,
            onFocusHistoryForward: onFocusHistoryForward,
            visibilityMode: .alwaysVisible
        )
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
        ))

        controls.onToggleNotifications = { [weak controlsViewModel] in
            onToggleNotifications(controlsViewModel?.notificationsAnchorView)
        }
        addSubview(hitRegionView)
        addSubview(gapDragView)
        addSubview(controls)
        addSubview(hoverTrackingView)
        hoverTrackingView.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            isHoveringHost = hovering
            refreshVisibility()
        }

        MinimalModeSidebarChromeHoverState.shared.$hoveredWindowNumber
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hoveredWindowNumber in
                guard let self else { return }
                isHoveringWindowChrome = window?.windowNumber == hoveredWindowNumber
                refreshVisibility()
            }
            .store(in: &cancellables)
        NotificationsPopoverVisibilityState.shared.$shownWindowNumbers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        refreshConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: window)
        }
        refreshVisibility()
    }

    override func layout() {
        super.layout()
        let frame = bounds
        hitRegionView.frame = frame
        gapDragView.frame = frame
        controls.frame = frame
        hoverTrackingView.frame = frame
    }

    func refreshConfiguration() {
        let config = layoutModel.snapshot.style.config
        gapDragView.config = config
        hitRegionView.config = config
        controls.frame.size = intrinsicContentSize
        needsLayout = true
        refreshVisibility()
    }

    func update(
        onToggleSidebar: @escaping () -> Void,
        onToggleNotifications: @escaping (NSView?) -> Void,
        onNewTab: @escaping () -> Void,
        onFocusHistoryBack: @escaping () -> Void,
        onFocusHistoryForward: @escaping () -> Void
    ) {
        controls.update(
            onToggleSidebar: onToggleSidebar,
            onToggleNotifications: { [weak controlsViewModel] in
                onToggleNotifications(controlsViewModel?.notificationsAnchorView)
            },
            onNewTab: onNewTab,
            onFocusHistoryBack: onFocusHistoryBack,
            onFocusHistoryForward: onFocusHistoryForward,
            visibilityMode: .alwaysVisible
        )
        refreshConfiguration()
    }

    private func refreshVisibility() {
        let shown = isHoveringHost
            || isHoveringWindowChrome
            || NotificationsPopoverVisibilityState.shared.isShown(in: window?.windowNumber)
        controls.isHidden = !shown
        controls.alphaValue = shown ? 1 : 0
        hoverTrackingView.capturesPassiveHits = !shown
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

@MainActor
private final class PassthroughHoverTrackingNativeView: NSView {
    var capturesPassiveHits = true
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var localMouseMonitor: Any?
    private var isHovering = false
    private weak var mouseMovedWindow: NSWindow?
    private var isTrackingMouseMovedEvents = false

    deinit {
        MainActor.assumeIsolated {
            removeLocalMouseMonitor()
            stopMouseMovedTracking()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard NSEvent.pressedMouseButtons == 0 else { return nil }
        let event = NSApp.currentEvent
        switch event?.type {
        case .none, .mouseMoved, .mouseEntered, .mouseExited:
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

    override func layout() {
        super.layout()
        recordFrameForUITest()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(from: event) }
    override func mouseExited(with event: NSEvent) { updateHover(from: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(from: event) }

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
        _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
            envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"
        ) { payload in
            payload["minimalSidebarHostFrameInWindow"] = NSStringFromRect(frameInWindow)
        }
        #endif
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
    private let controlsView: TitlebarControlsView
    private let containerView: NSView
    private let notificationStore: TerminalNotificationStore
    private let layoutModel: TitlebarControlsLayoutModel
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
    private var lastShowsWorkspaceTitlebar = !WorkspacePresentationModeSettings.isMinimal()
    private var lastTitlebarDebugSnapshot = MinimalModeTitlebarDebugSettings.snapshot()
    var popoverIsShownForTesting: Bool { notificationsPopover.isShown }
    private var showsWorkspaceTitlebar: Bool { !WorkspacePresentationModeSettings.isMinimal() }

    init(
        notificationStore: TerminalNotificationStore,
        settingsRuntime _: SettingsRuntime?,
        layoutModel: TitlebarControlsLayoutModel
    ) {
        let containerView = TitlebarAccessoryContainerView()
        self.containerView = containerView
        self.notificationStore = notificationStore
        self.layoutModel = layoutModel
        let prepareOriginatingAction: () -> AppDelegate.MainWindowContext? = { [weak containerView] in
            guard let appDelegate = AppDelegate.shared,
                  let window = containerView?.window else {
                return nil
            }
            return appDelegate.prepareSenderRelativeMainWindowAction(in: window)
        }
        let toggleSidebar = { [weak containerView] in
            _ = AppDelegate.shared?.toggleSidebarInActiveMainWindow(preferredWindow: containerView?.window)
        }
        let toggleNotifications: () -> Void = { [weak containerView] in
            guard prepareOriginatingAction() != nil else { return }
            _ = AppDelegate.shared?.toggleNotificationsPopover(animated: true, anchorView: containerView)
        }
        let newTab = {
            guard let appDelegate = AppDelegate.shared,
                  let context = prepareOriginatingAction() else { return }
            _ = appDelegate.performNewWorkspaceAction(
                tabManager: context.tabManager,
                debugSource: "titlebar.accessoryNewWorkspace"
            )
        }
        let focusHistoryBack = {
            _ = prepareOriginatingAction()?.tabManager.navigateBack()
        }
        let focusHistoryForward = {
            _ = prepareOriginatingAction()?.tabManager.navigateForward()
        }
        controlsView = TitlebarControlsView(
            unreadModel: notificationStore.sidebarUnread,
            layoutModel: layoutModel,
            viewModel: viewModel,
            onToggleSidebar: toggleSidebar,
            onToggleNotifications: toggleNotifications,
            onNewTab: newTab,
            onFocusHistoryBack: focusHistoryBack,
            onFocusHistoryForward: focusHistoryForward,
            visibilityMode: .alwaysVisible
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
        // `clipsToBounds = false` on both the container and the controls view so
        // the non-clipping intent persists across layout on every macOS version.
        containerView.wantsLayer = true
        containerView.clipsToBounds = false
        containerView.layer?.masksToBounds = false
        controlsView.translatesAutoresizingMaskIntoConstraints = true
        controlsView.autoresizingMask = []
        controlsView.clipsToBounds = false
        controlsView.layer?.masksToBounds = false
        containerView.addSubview(controlsView)

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let shouldShow = self.showsWorkspaceTitlebar
            let debugSnapshot = MinimalModeTitlebarDebugSettings.snapshot()
            let visibilityChanged = shouldShow != self.lastShowsWorkspaceTitlebar
            let debugLayoutChanged = debugSnapshot != self.lastTitlebarDebugSnapshot
            guard visibilityChanged || debugLayoutChanged else { return }
            self.lastTitlebarDebugSnapshot = debugSnapshot
            if visibilityChanged {
                self.applyWorkspaceTitlebarVisibility()
                if shouldShow {
                    self.restoreSizeAfterMinimalMode()
                }
            }
            if debugLayoutChanged, shouldShow {
                self.scheduleSizeUpdate(invalidateLayout: true)
            }
        }
        observeLayoutModel()

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

    private func observeLayoutModel() {
        withObservationTracking {
            _ = layoutModel.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSizeUpdate(
                    invalidateIntrinsicSize: true,
                    invalidateLayout: true
                )
                self.observeLayoutModel()
            }
        }
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
        let contentSize = layoutModel.snapshot.contentSize
        if intrinsicSizeNeedsRefresh {
            controlsView.invalidateIntrinsicContentSize()
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
        controlsView.frame = NSRect(x: xOffset, y: yOffset, width: contentSize.width, height: contentSize.height)
    }

    private func applyWorkspaceTitlebarVisibility() {
        let shouldShow = showsWorkspaceTitlebar
        lastShowsWorkspaceTitlebar = shouldShow
        self.isHidden = !shouldShow
        view.isHidden = !shouldShow
        view.alphaValue = shouldShow ? 1 : 0
        if !shouldShow {
            preferredContentSize = .zero
        }
    }

    /// Restore the accessory size after it was zeroed in minimal mode.
    /// Seeds the controls view with a non-zero frame before deterministic sizing
    /// runs again after the view was collapsed.
    private func restoreSizeAfterMinimalMode() {
        guard showsWorkspaceTitlebar else { return }
        let seed = cachedContentSize ?? NSSize(width: 200, height: 28)
        if controlsView.frame.size == .zero || containerView.frame.size == .zero {
            containerView.frame.size = seed
            controlsView.frame.size = seed
        }
        scheduleSizeUpdate(invalidateIntrinsicSize: true)
    }

    func toggleNotificationsPopover(animated: Bool = true, externalAnchor: NSView? = nil) {
        if notificationsPopover.isShown {
            notificationsPopover.animates = animated
            notificationsPopover.performClose(nil)
            return
        }
        // Recreate the controller each time so hidden popovers release all observers.
        let contentController = NotificationsPopoverViewController(
            notificationStore: notificationStore,
            onDismiss: { [weak notificationsPopover] in
                notificationsPopover?.performClose(nil)
            }
        )
        contentController.view.wantsLayer = true
        contentController.view.layer?.backgroundColor = .clear
        notificationsPopover.contentViewController = contentController

        guard let window = externalAnchor?.window ?? view.window ?? controlsView.window ?? NSApp.keyWindow,
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
        // Release native observations when the popover is hidden.
        notificationsPopover.contentViewController = nil
        postNotificationsPopoverVisibilityDidChange(isShown: false, source: notificationsPopover)
    }
}

@MainActor
final class UpdateTitlebarAccessoryController {
    private let updateLog: UpdateLogStore
    private let settingsRuntime: SettingsRuntime?
    private let layoutModel: TitlebarControlsLayoutModel
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

    init(
        updateLog: UpdateLogStore,
        settingsRuntime: SettingsRuntime?,
        layoutModel: TitlebarControlsLayoutModel
    ) {
        self.updateLog = updateLog
        self.settingsRuntime = settingsRuntime
        self.layoutModel = layoutModel
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
        // We want to be robust to legacy scene/AppKit timing and to XCTest automation. Scanning
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

        // Window identifiers are assigned by the legacy scene bridge, which can run
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
                settingsRuntime: settingsRuntime,
                layoutModel: layoutModel
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
        popover.contentViewController = NotificationsPopoverViewController(
            notificationStore: TerminalNotificationStore.shared,
            onDismiss: { [weak popover] in
                popover?.performClose(nil)
            }
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
