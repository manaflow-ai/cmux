import AppKit
import CmuxSettings
import DynamicNotchKit
import SwiftUI

extension DynamicNotchAppearance {
    func dimension(_ token: DynamicNotchAppearanceToken) -> CGFloat {
        guard case .number(let value) = self[token] else { return 0 }
        return CGFloat(value)
    }

    func integer(_ token: DynamicNotchAppearanceToken) -> Int {
        guard case .integer(let value) = self[token] else { return 0 }
        return value
    }

    func boolean(_ token: DynamicNotchAppearanceToken) -> Bool {
        guard case .boolean(let value) = self[token] else { return false }
        return value
    }

    func color(
        _ token: DynamicNotchAppearanceToken,
        system fallback: Color
    ) -> Color {
        explicitColor(token) ?? fallback
    }

    var usesNativeInputStyle: Bool {
        [
            .inputCornerRadius,
            .inputHorizontalPadding,
            .inputVerticalPadding,
            .inputBorderWidth,
            .inputBackgroundColor,
            .inputTextColor,
            .inputBorderColor,
        ].allSatisfy { self[$0] == $0.defaultValue }
    }

    var dynamicNotchChrome: DynamicNotchChrome {
        let shellPadding = dimension(.shellPadding)
        let borderWidth = dimension(.shellBorderWidth)
        let borderIsNative = explicitColor(.shellBorderColor) == nil
            && self[.shellBorderWidth] == DynamicNotchAppearanceToken.shellBorderWidth.defaultValue

        return DynamicNotchChrome(
            backgroundColor: explicitColor(.shellBackgroundColor),
            backgroundOpacity: Double(dimension(.shellBackgroundOpacity)),
            borderColor: explicitColor(.shellBorderColor),
            borderWidth: borderIsNative ? nil : borderWidth,
            shadowColor: explicitColor(.shadowColor),
            shadowOpacity: Double(dimension(.shadowOpacity)),
            shadowRadius: dimension(.shadowRadius),
            hoverShadowOpacity: Double(dimension(.hoverShadowOpacity)),
            hoverShadowRadius: dimension(.hoverShadowRadius),
            floatingOuterPadding: dimension(.floatingOuterPadding),
            floatingContentInsets: EdgeInsets(
                top: shellPadding,
                leading: shellPadding,
                bottom: shellPadding,
                trailing: shellPadding
            ),
            notchContentInsets: EdgeInsets(
                top: 0,
                leading: shellPadding,
                bottom: shellPadding,
                trailing: shellPadding
            ),
            floatingCornerRadius: dimension(.floatingCornerRadius),
            notchTopCornerRadius: dimension(.notchTopCornerRadius),
            notchBottomCornerRadius: dimension(.notchBottomCornerRadius),
            syntheticNotchWidth: dimension(.syntheticNotchWidth)
        )
    }

    func explicitColor(
        _ token: DynamicNotchAppearanceToken
    ) -> Color? {
        guard case .color(let value) = self[token] else { return nil }
        switch value {
        case .system:
            return nil
        case .hex(let hex):
            let digits = hex.dropFirst()
            guard let rgb = UInt32(digits, radix: 16) else { return nil }
            return Color(
                .sRGB,
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                opacity: 1
            )
        }
    }
}
