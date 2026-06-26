public import Foundation

/// Selectable visual treatment for the PDF preview's floating chrome controls.
///
/// The selection is persisted in DEBUG builds under `defaultsKey`; `current()`
/// reads it and `persist()` writes it and announces the change. The localized,
/// human-readable `title` for each case lives app-side (it depends on the app
/// bundle's `String(localized:)` catalog), so it is not part of this value type.
public enum FilePreviewPDFChromeStyleVariant: String, CaseIterable, Identifiable {
    case systemControlGroup
    case liquidGlass
    case materialCapsule
    case borderedCapsule
    case thinOutline
    case plainToolbar

    /// `UserDefaults` key backing the persisted chrome-style selection.
    public static let defaultsKey = "filePreviewPDFChromeStyleVariant"

    /// Stable identity for `Identifiable`; the raw value doubles as the id.
    public var id: String { rawValue }

    /// The persisted variant in DEBUG builds, defaulting to `.liquidGlass` when
    /// nothing valid is stored (and always `.liquidGlass` in release builds).
    public static func current() -> FilePreviewPDFChromeStyleVariant {
        #if DEBUG
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let variant = FilePreviewPDFChromeStyleVariant(rawValue: rawValue) {
            return variant
        }
        #endif
        return .liquidGlass
    }

    /// Persists this variant (DEBUG only) and posts
    /// `.filePreviewPDFChromeStyleDidChange` so live previews can react.
    public func persist() {
        #if DEBUG
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .filePreviewPDFChromeStyleDidChange, object: nil)
        #endif
    }
}

extension Notification.Name {
    /// Posted when the persisted PDF preview chrome style changes (DEBUG only).
    public static let filePreviewPDFChromeStyleDidChange = Notification.Name("filePreviewPDFChromeStyleDidChange")
}
