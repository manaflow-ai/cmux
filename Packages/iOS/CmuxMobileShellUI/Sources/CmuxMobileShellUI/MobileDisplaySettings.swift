import Foundation
import Observation

/// User-tunable display preferences for the mobile workspace UI, persisted to an
/// injected ``UserDefaults``.
///
/// Constructed once at the app composition root and injected into the SwiftUI
/// environment (no singleton). Views read it through `@Environment` and bind to
/// it with `@Bindable`; the `@Observable` conformance drives re-renders when a
/// preference changes. The backing store is injected so tests pass a scoped
/// `UserDefaults(suiteName:)` instead of polluting `.standard`.
///
/// ```swift
/// let settings = MobileDisplaySettings(defaults: UserDefaults(suiteName: "test")!)
/// settings.wrapWorkspaceTitles = true // persisted to the injected defaults
/// ```
@MainActor
@Observable
public final class MobileDisplaySettings {
    // UserDefaults is Apple-documented thread-safe; the synchronous read in
    // `init` and the write-through in `didSet` are safe nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let wrapWorkspaceTitlesKey = "cmux.mobile.wrapWorkspaceTitles"
    private static let showAltScreenNoticeKey = "cmux.mobile.showAltScreenNotice"
    private static let workspacePreviewLineCountKey = "cmux.mobile.workspacePreviewLineCount"
    private static let unreadIndicatorLeftShiftKey = "cmux.mobile.debug.unreadIndicatorLeftShift.v2"
    private static let profilePictureLeftShiftKey = "cmux.mobile.debug.profilePictureLeftShift"
    private static let profilePictureSizeKey = "cmux.mobile.debug.profilePictureSize"

    /// The preview line counts the "Preview Lines" setting offers.
    public static let workspacePreviewLineCountRange = 1...2
    /// Default preview line count when nothing is stored (iMessage-style two
    /// lines).
    public static let defaultWorkspacePreviewLineCount = 2
    /// Debug slider range for moving the unread dot left, in points.
    public static let unreadIndicatorLeftShiftRange: ClosedRange<Double> = 0...24
    /// Debug slider range for moving the workspace profile picture left, in points.
    public static let profilePictureLeftShiftRange: ClosedRange<Double> = 0...24
    /// Debug slider range for the workspace profile picture size, in points.
    public static let profilePictureSizeRange: ClosedRange<Double> = 36...64
    /// With the workspace list's 12pt leading row inset, 10pt unread gutter, and
    /// 11pt unread dot, this places the dot's leading edge 10pt from the screen.
    public static let defaultUnreadIndicatorLeftShift = 1.5
    public static let defaultProfilePictureLeftShift = 4.0
    public static let defaultProfilePictureSize = 45.0

    /// Whether workspace-list row titles wrap onto multiple lines instead of
    /// truncating to a single line. Defaults to `false` (single-line). Mutating
    /// this writes through to the injected ``UserDefaults``.
    public var wrapWorkspaceTitles: Bool {
        didSet { defaults.set(wrapWorkspaceTitles, forKey: Self.wrapWorkspaceTitlesKey) }
    }

    /// Whether the alternate-screen sizing notice is shown. Defaults to `true`.
    /// The notice's "Don't Show Again" action sets this to `false`; mutating
    /// this writes through to the injected ``UserDefaults``.
    public var showAltScreenNotice: Bool {
        didSet { defaults.set(showAltScreenNotice, forKey: Self.showAltScreenNoticeKey) }
    }

    /// How many lines a workspace row's activity preview shows (1 or 2).
    /// Defaults to 2. Mutating this clamps to the supported range and writes
    /// through to the injected ``UserDefaults``.
    public var workspacePreviewLineCount: Int {
        didSet {
            let clamped = Self.clampedWorkspacePreviewLineCount(workspacePreviewLineCount)
            // Assigning inside didSet does not re-trigger the observer.
            if clamped != workspacePreviewLineCount { workspacePreviewLineCount = clamped }
            defaults.set(clamped, forKey: Self.workspacePreviewLineCountKey)
        }
    }

    /// DEBUG-only layout tuning value, exposed in Settings > Developer. Positive
    /// values move the unread indicator left without changing row column widths.
    public var unreadIndicatorLeftShift: Double {
        didSet {
            let clamped = Self.clamped(unreadIndicatorLeftShift, to: Self.unreadIndicatorLeftShiftRange)
            if clamped != unreadIndicatorLeftShift { unreadIndicatorLeftShift = clamped }
            defaults.set(clamped, forKey: Self.unreadIndicatorLeftShiftKey)
        }
    }

    /// DEBUG-only layout tuning value, exposed in Settings > Developer. Positive
    /// values move the workspace profile picture left without changing text layout.
    public var profilePictureLeftShift: Double {
        didSet {
            let clamped = Self.clamped(profilePictureLeftShift, to: Self.profilePictureLeftShiftRange)
            if clamped != profilePictureLeftShift { profilePictureLeftShift = clamped }
            defaults.set(clamped, forKey: Self.profilePictureLeftShiftKey)
        }
    }

    /// DEBUG-only layout tuning value, exposed in Settings > Developer.
    public var profilePictureSize: Double {
        didSet {
            let clamped = Self.clamped(profilePictureSize, to: Self.profilePictureSizeRange)
            if clamped != profilePictureSize { profilePictureSize = clamped }
            defaults.set(clamped, forKey: Self.profilePictureSizeKey)
        }
    }

    /// Creates the display settings, seeding stored values from `defaults`.
    /// - Parameter defaults: The store backing the persisted preferences.
    ///   Defaults to `.standard`; tests pass a scoped suite. Stored properties
    ///   are initialized from `defaults`; absent keys read as their default
    ///   (single-line titles, two preview lines) without a write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wrapWorkspaceTitles = defaults.bool(forKey: Self.wrapWorkspaceTitlesKey)
        self.showAltScreenNotice = defaults.object(forKey: Self.showAltScreenNoticeKey) as? Bool ?? true
        let storedPreviewLines = defaults.object(forKey: Self.workspacePreviewLineCountKey) as? Int
        self.workspacePreviewLineCount = Self.clampedWorkspacePreviewLineCount(
            storedPreviewLines ?? Self.defaultWorkspacePreviewLineCount
        )
        let storedUnreadLeftShift = defaults.object(forKey: Self.unreadIndicatorLeftShiftKey) as? Double
        self.unreadIndicatorLeftShift = Self.clamped(
            storedUnreadLeftShift ?? Self.defaultUnreadIndicatorLeftShift,
            to: Self.unreadIndicatorLeftShiftRange
        )
        let storedProfileLeftShift = defaults.object(forKey: Self.profilePictureLeftShiftKey) as? Double
        self.profilePictureLeftShift = Self.clamped(
            storedProfileLeftShift ?? Self.defaultProfilePictureLeftShift,
            to: Self.profilePictureLeftShiftRange
        )
        let storedProfilePictureSize = defaults.object(forKey: Self.profilePictureSizeKey) as? Double
        self.profilePictureSize = Self.clamped(
            storedProfilePictureSize ?? Self.defaultProfilePictureSize,
            to: Self.profilePictureSizeRange
        )
    }

    /// Clamps a stored or assigned preview line count to the supported range.
    /// A static member (not a file-scope func) because the package-conventions
    /// linter forbids free functions in the mobile packages.
    private static func clampedWorkspacePreviewLineCount(_ count: Int) -> Int {
        min(
            max(count, workspacePreviewLineCountRange.lowerBound),
            workspacePreviewLineCountRange.upperBound
        )
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
