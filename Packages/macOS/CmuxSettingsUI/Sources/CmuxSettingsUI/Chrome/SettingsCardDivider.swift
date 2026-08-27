import AppKit
import SwiftUI

/// 1pt half-opacity separator drawn between two ``SettingsCardRow``s
/// inside a ``SettingsCard``.
@MainActor
public struct SettingsCardDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color(nsColor: NSColor.separatorColor).opacity(0.5))
            .frame(height: 1)
    }
}
