#if DEBUG
import SwiftUI

/// Renders one terminal fixture line in the fixed dark artifact palette.
struct AtelierTerminalLineView: View {
    let line: GalleryTerminalLine

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = AtelierTheme(scheme: colorScheme)

        Text(line.text)
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(lineColor(theme: theme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lineColor(theme: AtelierTheme) -> Color {
        switch line.tone {
        case .plain: theme.terminalPlain
        case .dim: theme.terminalDim
        case .accent: theme.terminalAccent
        case .success: theme.terminalSuccess
        case .warning: theme.terminalWarning
        case .error: theme.terminalError
        }
    }
}
#endif
