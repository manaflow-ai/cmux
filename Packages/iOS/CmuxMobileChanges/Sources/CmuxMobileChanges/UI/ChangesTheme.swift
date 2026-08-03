internal import Foundation

#if canImport(UIKit)
internal import UIKit
#endif

/// Light or dark native appearance used to resolve diff colors.
public enum ChangesAppearance: Sendable {
    case light
    case dark
}

/// Framework-neutral RGBA token. UIKit rendering resolves this to `UIColor`.
public struct ChangesColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    #if canImport(UIKit)
    @MainActor
    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}

/// Central visual tokens for workspace change lists and diff pages.
public struct ChangesTheme: Sendable {
    public let additionBackground: ChangesColor
    public let additionEmphasis: ChangesColor
    public let removalBackground: ChangesColor
    public let removalEmphasis: ChangesColor
    public let hunkHeaderBackground: ChangesColor
    public let hunkHeaderText: ChangesColor
    public let gutterText: ChangesColor
    public let gutterSeparator: ChangesColor
    public let addedStatus: ChangesColor
    public let deletedStatus: ChangesColor
    public let rowVerticalPadding: Double
    public let hunkSpacing: Double
    public let groupedCornerRadius: Double

    public init(appearance: ChangesAppearance) {
        let isDark = appearance == .dark
        additionBackground = isDark
            ? ChangesColor(red: 46 / 255, green: 160 / 255, blue: 67 / 255, alpha: 0.15)
            : ChangesColor(red: 230 / 255, green: 1, blue: 236 / 255)
        additionEmphasis = isDark
            ? ChangesColor(red: 46 / 255, green: 160 / 255, blue: 67 / 255, alpha: 0.40)
            : ChangesColor(red: 171 / 255, green: 242 / 255, blue: 188 / 255)
        removalBackground = isDark
            ? ChangesColor(red: 248 / 255, green: 81 / 255, blue: 73 / 255, alpha: 0.15)
            : ChangesColor(red: 1, green: 235 / 255, blue: 233 / 255)
        removalEmphasis = isDark
            ? ChangesColor(red: 248 / 255, green: 81 / 255, blue: 73 / 255, alpha: 0.40)
            : ChangesColor(red: 1, green: 192 / 255, blue: 192 / 255)
        hunkHeaderBackground = isDark
            ? ChangesColor(red: 56 / 255, green: 139 / 255, blue: 253 / 255, alpha: 0.15)
            : ChangesColor(red: 221 / 255, green: 244 / 255, blue: 1)
        hunkHeaderText = isDark
            ? ChangesColor(red: 139 / 255, green: 181 / 255, blue: 246 / 255)
            : ChangesColor(red: 75 / 255, green: 110 / 255, blue: 140 / 255)
        gutterText = ChangesColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.72)
        gutterSeparator = ChangesColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.22)
        addedStatus = ChangesColor(red: 46 / 255, green: 160 / 255, blue: 67 / 255)
        deletedStatus = ChangesColor(red: 248 / 255, green: 81 / 255, blue: 73 / 255)
        rowVerticalPadding = 2
        hunkSpacing = 8
        groupedCornerRadius = 10
    }

    #if canImport(UIKit)
    @MainActor
    init(traitCollection: UITraitCollection) {
        self.init(appearance: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }
    #endif
}
