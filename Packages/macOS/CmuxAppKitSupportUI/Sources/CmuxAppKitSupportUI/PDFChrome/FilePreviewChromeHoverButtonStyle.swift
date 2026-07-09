import SwiftUI

/// The button style backing ``FilePreviewChromeIconButton``: tints the label and
/// draws a rounded backing rectangle whose fill opacity reflects pressed/hover state.
///
/// `isHovered` is supplied by the hosting button because `ButtonStyle.Configuration`
/// exposes only `isPressed`, not hover.
struct FilePreviewChromeHoverButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed || isHovered ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.24 : (isHovered ? 0.14 : 0)))
                    .frame(width: 32, height: 32)
            }
    }
}
