import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceLayoutTabChromeDebugSettings {
    static let closeGlyphDXKey = "workspaceTabChrome.closeGlyphDX"
    static let closeGlyphDYKey = "workspaceTabChrome.closeGlyphDY"
    static let closeCircleDXKey = "workspaceTabChrome.closeCircleDX"
    static let closeCircleDYKey = "workspaceTabChrome.closeCircleDY"
    static let closeCircleSizeDeltaKey = "workspaceTabChrome.closeCircleSizeDelta"
    static let defaultCloseGlyphDX = 0.0
    static let defaultCloseGlyphDY = 0.0
    static let defaultCloseCircleDX = 0.0
    static let defaultCloseCircleDY = 0.0
    static let defaultCloseCircleSizeDelta = 0.0
    static let closeGlyphOffsetRange: ClosedRange<Double> = -4...4
    static let closeCircleSizeDeltaRange: ClosedRange<Double> = -6...8

    static func clamped(_ value: Double) -> Double {
        min(max(value, closeGlyphOffsetRange.lowerBound), closeGlyphOffsetRange.upperBound)
    }

    static func clampedCircleSizeDelta(_ value: Double) -> Double {
        min(max(value, closeCircleSizeDeltaRange.lowerBound), closeCircleSizeDeltaRange.upperBound)
    }

    static func closeGlyphDX(userDefaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            clamped(
                userDefaults.object(forKey: closeGlyphDXKey) as? Double
                    ?? defaultCloseGlyphDX
            )
        )
    }

    static func closeGlyphDY(userDefaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            clamped(
                userDefaults.object(forKey: closeGlyphDYKey) as? Double
                    ?? defaultCloseGlyphDY
            )
        )
    }

    static func closeCircleDX(userDefaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            clamped(
                userDefaults.object(forKey: closeCircleDXKey) as? Double
                    ?? defaultCloseCircleDX
            )
        )
    }

    static func closeCircleDY(userDefaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            clamped(
                userDefaults.object(forKey: closeCircleDYKey) as? Double
                    ?? defaultCloseCircleDY
            )
        )
    }

    static func closeCircleSizeDelta(userDefaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(
            clampedCircleSizeDelta(
                userDefaults.object(forKey: closeCircleSizeDeltaKey) as? Double
                    ?? defaultCloseCircleSizeDelta
            )
        )
    }
}

enum WorkspaceLayoutTabChromeAccessoryMetrics {
    static let baseDY = CGFloat(-0.359375)
    static let basePointSizeDelta = CGFloat(0.09375)
    static let baseCloseCircleDY = CGFloat(-1)
}

func workspaceLayoutDebugPreview(_ text: String, limit: Int = 120) -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    return "\(escaped.prefix(limit))..."
}

struct WorkspaceLayoutTabChromeDebugTuning {
    let titleDX: CGFloat
    let titleDY: CGFloat
    let titlePointSizeDelta: CGFloat
    let titleKern: CGFloat
    let iconDX: CGFloat
    let iconDY: CGFloat
    let iconPointSizeDelta: CGFloat
    let accessoryDX: CGFloat
    let accessoryDY: CGFloat
    let accessoryPointSizeDelta: CGFloat
    let closeGlyphDX: CGFloat
    let closeGlyphDY: CGFloat
    let closeCircleDX: CGFloat
    let closeCircleDY: CGFloat
    let closeCircleSizeDelta: CGFloat

    static var current: WorkspaceLayoutTabChromeDebugTuning {
        WorkspaceLayoutTabChromeDebugTuning()
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        titleDX = Self.cgFloat("CMUX_TAB_CHROME_TITLE_DX", environment: environment, defaultValue: 1)
        titleDY = Self.cgFloat("CMUX_TAB_CHROME_TITLE_DY", environment: environment, defaultValue: 0.375)
        titlePointSizeDelta = Self.cgFloat("CMUX_TAB_CHROME_TITLE_POINT_SIZE_DELTA", environment: environment)
        titleKern = Self.cgFloat("CMUX_TAB_CHROME_TITLE_KERN", environment: environment)
        iconDX = Self.cgFloat("CMUX_TAB_CHROME_ICON_DX", environment: environment, defaultValue: -1)
        iconDY = Self.cgFloat("CMUX_TAB_CHROME_ICON_DY", environment: environment, defaultValue: -0.875)
        iconPointSizeDelta = Self.cgFloat("CMUX_TAB_CHROME_ICON_POINT_SIZE_DELTA", environment: environment, defaultValue: -0.5)
        accessoryDX = Self.cgFloat("CMUX_TAB_CHROME_ACCESSORY_DX", environment: environment)
        accessoryDY = Self.cgFloat(
            "CMUX_TAB_CHROME_ACCESSORY_DY",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeAccessoryMetrics.baseDY
        )
        accessoryPointSizeDelta = Self.cgFloat(
            "CMUX_TAB_CHROME_ACCESSORY_POINT_SIZE_DELTA",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeAccessoryMetrics.basePointSizeDelta
        )
        closeGlyphDX = Self.cgFloat(
            "CMUX_TAB_CHROME_CLOSE_GLYPH_DX",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeDebugSettings.closeGlyphDX()
        )
        closeGlyphDY = Self.cgFloat(
            "CMUX_TAB_CHROME_CLOSE_GLYPH_DY",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeDebugSettings.closeGlyphDY()
        )
        closeCircleDX = Self.cgFloat(
            "CMUX_TAB_CHROME_CLOSE_CIRCLE_DX",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeDebugSettings.closeCircleDX()
        )
        closeCircleDY = Self.cgFloat(
            "CMUX_TAB_CHROME_CLOSE_CIRCLE_DY",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeAccessoryMetrics.baseCloseCircleDY
                + WorkspaceLayoutTabChromeDebugSettings.closeCircleDY()
        )
        closeCircleSizeDelta = Self.cgFloat(
            "CMUX_TAB_CHROME_CLOSE_CIRCLE_SIZE_DELTA",
            environment: environment,
            defaultValue: WorkspaceLayoutTabChromeDebugSettings.closeCircleSizeDelta()
        )
    }

    static func cgFloat(
        _ key: String,
        environment: [String: String],
        defaultValue: CGFloat = 0
    ) -> CGFloat {
        guard let raw = environment[key], let value = Double(raw) else {
            return defaultValue
        }
        return CGFloat(value)
    }
}

enum WorkspaceLayoutTabChromeTitleRenderer: String {
    case stringDraw
    case textKit

    static let current: WorkspaceLayoutTabChromeTitleRenderer = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["CMUX_TAB_CHROME_TITLE_RENDERER"],
           let renderer = WorkspaceLayoutTabChromeTitleRenderer(rawValue: raw) {
            return renderer
        }
#endif
        return .stringDraw
    }()
}

enum WorkspaceLayoutTabChromeTitleDrawMode: String {
    case current
    case noLeading
    case deviceMetrics
    case noLeadingDeviceMetrics
    case disableScreenFontSubstitution

    private static let disableScreenFontSubstitutionOption = NSString.DrawingOptions(rawValue: 1 << 2)

    static let selected: WorkspaceLayoutTabChromeTitleDrawMode = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["CMUX_TAB_CHROME_TITLE_DRAW_MODE"],
           let mode = WorkspaceLayoutTabChromeTitleDrawMode(rawValue: raw) {
            return mode
        }
#endif
        return .current
    }()

    var options: NSString.DrawingOptions {
        switch self {
        case .current:
            return [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        case .noLeading:
            return [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        case .deviceMetrics:
            return [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine, .usesDeviceMetrics]
        case .noLeadingDeviceMetrics:
            return [.usesLineFragmentOrigin, .truncatesLastVisibleLine, .usesDeviceMetrics]
        case .disableScreenFontSubstitution:
            return [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine, Self.disableScreenFontSubstitutionOption]
        }
    }
}

enum WorkspaceLayoutTabChromeContentRenderer: String {
    case customDraw
    case appKitSubviews

    static let current: WorkspaceLayoutTabChromeContentRenderer = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["CMUX_TAB_CHROME_CONTENT_RENDERER"],
           let renderer = WorkspaceLayoutTabChromeContentRenderer(rawValue: raw) {
            return renderer
        }
#endif
        return .appKitSubviews
    }()
}

enum WorkspaceLayoutTabChromeSubviewTitleRenderer: String {
    case label
    case draw

    static let current: WorkspaceLayoutTabChromeSubviewTitleRenderer = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["CMUX_TAB_CHROME_SUBVIEW_TITLE_RENDERER"],
           let renderer = WorkspaceLayoutTabChromeSubviewTitleRenderer(rawValue: raw) {
            return renderer
        }
#endif
        return .draw
    }()
}

enum WorkspaceLayoutTabChromeTitleSource: String {
    case auto
    case draw
    case label

    static let current: WorkspaceLayoutTabChromeTitleSource = {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["CMUX_TAB_CHROME_TITLE_SOURCE"],
           let source = WorkspaceLayoutTabChromeTitleSource(rawValue: raw) {
            return source
        }
#endif
        return .draw
    }()
}
