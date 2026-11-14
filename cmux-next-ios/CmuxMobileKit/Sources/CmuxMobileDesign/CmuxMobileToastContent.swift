#if os(iOS)
import SwiftUI

/// The production toast's content, also drawn without a timer in the material gallery.
public struct CmuxMobileToastContent: View {
    private let toast: CmuxMobileToast
    private let material: CmuxMobileTransientMaterial?

    /// Nil retains the original glass for chat-owned toast presentations.
    public init(_ toast: CmuxMobileToast, material: CmuxMobileTransientMaterial? = nil) {
        self.toast = toast
        self.material = material
    }

    public var body: some View {
        let theme = CmuxMobileTheme.standard
        HStack(spacing: 8) {
            if let symbol = toast.symbol { Image(systemName: symbol) }
            Text(toast.text)
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .cmuxMobileTransientGlass(in: .capsule, material: material)
    }
}
#endif
