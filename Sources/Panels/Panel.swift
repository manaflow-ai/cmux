import Foundation
import Combine
import AppKit
import SwiftUI
import CmuxCore
import CmuxTerminalCore
import CmuxWorkspaces

/// Type of panel content
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview = "filepreview"
    case rightSidebarTool
    case agentSession
    case project
    case extensionBrowser

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
        if rawValue.lowercased() == Self.rightSidebarTool.rawValue.lowercased() {
            self = .rightSidebarTool
            return
        }
        if rawValue.lowercased() == Self.agentSession.rawValue.lowercased() {
            self = .agentSession
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

extension PanelType {
    /// The workspace ``SurfaceKind`` a panel of this type registers as on its
    /// bonsplit tab and in session snapshots.
    ///
    /// Faithful lift of the private `Workspace.surfaceKind(for:)` switch onto the
    /// owning type. The mapping is deliberately NOT identity over `rawValue`:
    /// `PanelType.filePreview.rawValue` is `"filepreview"` while the persisted
    /// surface kind is `SurfaceKind.filePreview` (`"filePreview"`), so the
    /// explicit case mapping is preserved rather than collapsed.
    public var surfaceKind: SurfaceKind {
        switch self {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .extensionBrowser
        }
    }

    /// Maps a normalized control-command surface-type token onto a ``PanelType``.
    ///
    /// Byte-faithful home of the duplicated `panelType(forRawToken:)` /
    /// `surfacePanelType(forRawToken:)` switches that the control-socket pane- and
    /// surface-create paths each carried. Both normalized the caller-supplied type
    /// string app-side (`TerminalController.v2NormalizedToken`, stripping
    /// `-`/`_`/spaces and lowercasing) and switched on the result; the
    /// normalization stays app-side while this owns the single case table.
    /// `agentSession` is accepted here (the pane-create path rejects it
    /// downstream), and `project`/`extensionBrowser` remain unmapped, exactly as
    /// the legacy switches did.
    public init?(normalizedControlToken token: String) {
        switch token {
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "markdown": self = .markdown
        case "filepreview": self = .filePreview
        case "rightsidebartool": self = .rightSidebarTool
        case "agentsession": self = .agentSession
        default: return nil
        }
    }
}

extension PanelType {
    /// Resolves a control-socket `type` token (from `pane.*`/`surface.*`
    /// commands) to a ``PanelType``, or `nil` when the token is unrecognized.
    ///
    /// Byte-faithful lift of the private `panelType(forRawToken:)` twin of
    /// `v2PanelType`: the raw token is normalized (strip `-`, `_`, and spaces,
    /// then lowercase) before matching, so `"file-preview"`, `"file_preview"`,
    /// and `"FilePreview"` all resolve to ``filePreview``. The normalization is
    /// inlined here (rather than calling the `TerminalController` helper) so the
    /// owning value type stays self-contained. Callers that want a default fall
    /// back to ``terminal`` via `?? .terminal`.
    public init?(controlToken raw: String) {
        let normalized = raw
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        switch normalized {
        case "terminal":
            self = .terminal
        case "browser":
            self = .browser
        case "markdown":
            self = .markdown
        case "filepreview":
            self = .filePreview
        case "rightsidebartool":
            self = .rightSidebarTool
        case "agentsession":
            self = .agentSession
        default:
            return nil
        }
    }
}

public enum TerminalPanelFocusIntent: Equatable {
    case surface
    case findField
    case textBoxInput
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

public enum ProjectPanelFocusIntent: Hashable {
    case navigator
    case detail
}

public enum PanelFocusIntent: Equatable {
    case panel
    case terminal(TerminalPanelFocusIntent)
    case browser(BrowserPanelFocusIntent)
    case filePreview(FilePreviewPanelFocusIntent)
    case project(ProjectPanelFocusIntent)
}

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionFlashReason`; this
/// typealias keeps the unqualified app-target call sites byte-identical.
public typealias WorkspaceAttentionFlashReason = CmuxCore.WorkspaceAttentionFlashReason

enum WorkspaceAttentionFlashAccent: Equatable, Sendable {
    case notificationBlue

    var strokeColor: NSColor {
        switch self {
        case .notificationBlue:
            return .systemBlue
        }
    }
}

struct WorkspaceAttentionFlashPresentation: Equatable, Sendable {
    let accent: WorkspaceAttentionFlashAccent
    let glowOpacity: Double
    let glowRadius: CGFloat

    /// Lowers this app-target presentation into the AppKit-free `Sendable` ring
    /// presentation consumed by the terminal-surface overlay container.
    ///
    /// Resolves the accent `NSColor` to straight sRGB components and folds in the
    /// shared ``PanelOverlayRingMetrics`` so the view layer never imports either
    /// the attention palette or the ring metrics.
    func ringPresentation() -> TerminalPaneRingPresentation {
        let color = accent.strokeColor.usingColorSpace(.sRGB) ?? accent.strokeColor
        return TerminalPaneRingPresentation(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent),
            glowOpacity: glowOpacity,
            glowRadius: glowRadius,
            lineWidth: PanelOverlayRingMetrics.lineWidth,
            inset: PanelOverlayRingMetrics.inset,
            cornerRadius: PanelOverlayRingMetrics.cornerRadius
        )
    }
}

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionPersistentState`;
/// this typealias keeps the unqualified app-target call sites byte-identical.
typealias WorkspaceAttentionPersistentState = CmuxCore.WorkspaceAttentionPersistentState

/// Canonical definition lives in `CmuxCore.WorkspaceAttentionFlashDecision`;
/// this typealias keeps the unqualified app-target call sites byte-identical.
typealias WorkspaceAttentionFlashDecision = CmuxCore.WorkspaceAttentionFlashDecision

/// The app-target presentation half of attention flashing.
///
/// The pure flash *decision* (`WorkspaceAttentionPersistentState`,
/// `WorkspaceAttentionFlashDecision.decide(...)`) moved to `CmuxCore` so the
/// `WorkspaceUnreadModel` can compute it; the ring colors/styles stay here
/// because they resolve to `NSColor`.
enum WorkspaceAttentionCoordinator {
    static let notificationRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.35,
        glowRadius: 3
    )

    static let flashRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.6,
        glowRadius: 6
    )

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation, .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return flashRingStyle
        }
    }
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

extension FocusFlashCurve {
    /// The SwiftUI `Animation` this focus-flash curve maps to for one segment's duration.
    func animation(duration: TimeInterval) -> Animation {
        switch self {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
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

    /// This pattern lowered into the AppKit-free `Sendable` spec the terminal
    /// overlay container animates from.
    static var paneAnimationSpec: TerminalPaneFlashAnimationSpec {
        TerminalPaneFlashAnimationSpec(
            values: values,
            keyTimes: keyTimes,
            duration: duration,
            curves: curves.map { curve in
                switch curve {
                case .easeIn: return .easeIn
                case .easeOut: return .easeOut
                }
            }
        )
    }
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
