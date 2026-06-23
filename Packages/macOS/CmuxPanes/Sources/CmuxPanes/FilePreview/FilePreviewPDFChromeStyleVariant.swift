public import Foundation

/// Visual style of the floating PDF preview chrome (zoom/sidebar controls).
///
/// `CaseIterable`/`Identifiable` so the debug picker can enumerate styles. The
/// `defaultsKey`/`current()`/`persist()` members are the DEBUG-only persistence
/// for the chrome-style experiment: they read and write `UserDefaults.standard`
/// and post `Notification.Name.filePreviewPDFChromeStyleDidChange` so open PDF
/// previews re-render with the chosen style. Outside `#if DEBUG` the style is
/// fixed to `.liquidGlass`.
public enum FilePreviewPDFChromeStyleVariant: String, CaseIterable, Identifiable, Sendable {
    case systemControlGroup
    case liquidGlass
    case materialCapsule
    case borderedCapsule
    case thinOutline
    case plainToolbar

    /// `UserDefaults` key backing the DEBUG chrome-style override.
    public static let defaultsKey = "filePreviewPDFChromeStyleVariant"

    public var id: String { rawValue }

    /// Localized, user-facing label for the style (debug picker rows).
    public var title: String {
        switch self {
        case .systemControlGroup:
            String(localized: "filePreview.pdf.chromeStyle.systemControlGroup", defaultValue: "A: System Control Group")
        case .liquidGlass:
            String(localized: "filePreview.pdf.chromeStyle.liquidGlass", defaultValue: "B: Liquid Glass")
        case .materialCapsule:
            String(localized: "filePreview.pdf.chromeStyle.materialCapsule", defaultValue: "C: Material Pill")
        case .borderedCapsule:
            String(localized: "filePreview.pdf.chromeStyle.borderedCapsule", defaultValue: "D: Bordered Controls")
        case .thinOutline:
            String(localized: "filePreview.pdf.chromeStyle.thinOutline", defaultValue: "E: Thin Outline")
        case .plainToolbar:
            String(localized: "filePreview.pdf.chromeStyle.plainToolbar", defaultValue: "F: Plain Toolbar")
        }
    }

    /// The active chrome style: the DEBUG `UserDefaults` override if present and
    /// valid, otherwise `.liquidGlass`. Always `.liquidGlass` in release builds.
    public static func current() -> FilePreviewPDFChromeStyleVariant {
        #if DEBUG
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let variant = FilePreviewPDFChromeStyleVariant(rawValue: rawValue) {
            return variant
        }
        #endif
        return .liquidGlass
    }

    /// Persists this style to the DEBUG `UserDefaults` override and notifies open
    /// PDF previews to re-render. No-op in release builds.
    public func persist() {
        #if DEBUG
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .filePreviewPDFChromeStyleDidChange, object: nil)
        #endif
    }
}

extension Notification.Name {
    /// Posted when the DEBUG PDF preview chrome style changes so open previews
    /// re-render with the newly selected `FilePreviewPDFChromeStyleVariant`.
    public static let filePreviewPDFChromeStyleDidChange = Notification.Name("filePreviewPDFChromeStyleDidChange")
}
