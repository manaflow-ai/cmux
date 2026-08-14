import CmuxSettings
import SwiftUI

/// 1pt half-opacity separator drawn between two ``SettingsCardRow``s
/// inside a ``SettingsCard``.
@MainActor
public struct SettingsCardDivider: View {
    @Environment(\.chromePalette) private var chromePalette

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(chromePalette.borderSubtle.swiftUIColor.opacity(0.5))
            .frame(height: 1)
    }
}
