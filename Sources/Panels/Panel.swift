import Foundation
import Combine
import AppKit

/// Type of panel content
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview = "filepreview"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let type = Self(rawValue: rawValue) {
            self = type
            return
        }
        if rawValue.lowercased() == Self.filePreview.rawValue {
            self = .filePreview
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unknown panel type: \(rawValue)"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
}

public enum BrowserPanelFocusIntent: Equatable {
    case webView
    case addressBar
    case findField
}

public enum FilePreviewPanelFocusIntent: Hashable {
    case textEditor
    case pdfCanvas
    case pdfThumbnails
    case pdfOutline
    case imageCanvas
    case mediaPlayer
    case quickLook
}

public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
    case filePreview(FilePreviewPanelFocusIntent)
}

public enum WorkspaceAttentionFlashReason: String, Equatable, Sendable {
    case navigation
    case notificationArrival
    case notificationDismiss
    case manualUnreadDismiss
    case debug
}

enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case notificationBlue
    case navigationTeal

    var strokeColor: NSColor {
        switch self {
        case .notificationBlue:
            return .systemBlue
        case .navigationTeal:
            return .systemTeal
        }
    }
}

struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    let accent: WorkspaceAttentionFlashAccent
    let glowOpacity: Double
    let glowRadius: CGFloat
}

struct WorkspaceAttentionPersistentState: Equatable, Sendable {
    var unreadPanelIDs: Set<UUID> = []
    var focusedReadPanelID: UUID?
    var manualUnreadPanelIDs: Set<UUID> = []

    var indicatorPanelIDs: Set<UUID> {
        var ids = unreadPanelIDs.union(manualUnreadPanelIDs)
        if let focusedReadPanelID {
            ids.insert(focusedReadPanelID)
        }
        return ids
    }

    func hasCompetingIndicator(for panelID: UUID) -> Bool {
        indicatorPanelIDs.contains(where: { $0 != panelID })
    }
}

struct WorkspaceAttentionFlashDecision: Equatable, Sendable {
    let panelID: UUID
    let reason: WorkspaceAttentionFlashReason
    let isAllowed: Bool
}

enum WorkspaceAttentionCoordinator {
    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation:
            return WorkspaceAttentionFlashPresentation(
                accent: .navigationTeal,
                glowOpacity: 0.14,
                glowRadius: 3
            )
        case .notificationArrival, .notificationDismiss, .manualUnreadDismiss, .debug:
            return WorkspaceAttentionFlashPresentation(
                accent: .notificationBlue,
                glowOpacity: 0.6,
                glowRadius: 6
            )
        }
    }

    static func decideFlash(
        targetPanelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        persistentState: WorkspaceAttentionPersistentState
    ) -> WorkspaceAttentionFlashDecision {
        let isAllowed: Bool
        switch reason {
        case .navigation:
            isAllowed = !persistentState.hasCompetingIndicator(for: targetPanelID)
        case .notificationArrival, .notificationDismiss, .manualUnreadDismiss, .debug:
            isAllowed = true
        }

        return WorkspaceAttentionFlashDecision(
            panelID: targetPanelID,
            reason: reason,
            isAllowed: isAllowed
        )
    }
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

enum PanelOverlayRingMetrics {
    static let inset: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    static let lineWidth: CGFloat = 2.5

    static func pathRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }
}

#if DEBUG
func cmuxFlashDebugID(_ id: UUID?) -> String {
    guard let id else { return "nil" }
    return String(id.uuidString.prefix(6))
}

func cmuxFlashDebugRect(_ rect: CGRect?) -> String {
    guard let rect else { return "nil" }
    return String(
        format: "%.1f,%.1f %.1fx%.1f",
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height
    )
}

func cmuxFlashDebugBool(_ value: Bool) -> Int {
    value ? 1 : 0
}
#endif

struct FocusFlashSegment: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
    let targetOpacity: Double
    let curve: FocusFlashCurve
}

enum FocusFlashPattern {
    static let values: [Double] = [0, 1, 0, 1, 0]
    static let keyTimes: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let duration: TimeInterval = 0.9
    static let curves: [FocusFlashCurve] = [.easeOut, .easeIn, .easeOut, .easeIn]
    static let ringInset: Double = Double(PanelOverlayRingMetrics.inset)
    static let ringCornerRadius: Double = Double(PanelOverlayRingMetrics.cornerRadius)

    static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }

    static func opacity(at elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }

        for index in 0..<segments.count {
            let startTime = keyTimes[index] * duration
            let endTime = keyTimes[index + 1] * duration
            if elapsed > endTime {
                continue
            }

            let segmentDuration = max(endTime - startTime, 0.0001)
            let rawProgress = max(0, min(1, (elapsed - startTime) / segmentDuration))
            let curvedProgress = interpolatedProgress(rawProgress, curve: curves[index])
            let startOpacity = values[index]
            let endOpacity = values[index + 1]
            return startOpacity + ((endOpacity - startOpacity) * curvedProgress)
        }

        return values.last ?? 0
    }

    private static func interpolatedProgress(_ progress: Double, curve: FocusFlashCurve) -> Double {
        switch curve {
        case .easeIn:
            return progress * progress
        case .easeOut:
            let inverse = 1 - progress
            return 1 - (inverse * inverse)
        }
    }
}

/// Protocol for all panel types (terminal, browser, etc.)
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash(reason: WorkspaceAttentionFlashReason)

    /// Capture the panel-local focus target that should be restored later.
    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent

    /// Return the best focus target to restore when this panel becomes active again.
    func preferredFocusIntentForActivation() -> PanelFocusIntent

    /// Prime panel-local focus state before activation side effects run.
    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent)

    /// Restore a previously captured focus target.
    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool

    /// Return the semantic focus target currently owned by this panel, if any.
    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent?

    /// Explicitly yield a previously owned focus target before another panel restores focus.
    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool
}

/// Extension providing default implementations
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        _ = window
        return preferredFocusIntentForActivation()
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .panel
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        _ = intent
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        guard intent == .panel else { return false }
        focus()
        return true
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = responder
        _ = window
        return nil
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        _ = intent
        _ = window
        return false
    }

    func triggerFlash() {
        triggerFlash(reason: .navigation)
    }
}
