#if DEBUG
import SwiftUI

/// Renders one fixed-size terminal line while preserving its fixture tone through weight and contrast.
struct SignalTerminalLineRow: View {
    let line: GalleryTerminalLine
    let theme: SignalTheme

    private var foreground: Color {
        if case .dim = line.tone { theme.secondaryText } else { theme.ink }
    }

    private var weight: Font.Weight {
        switch line.tone {
        case .success, .warning: .semibold
        case .error: .bold
        default: .regular
        }
    }

    var body: some View {
        Text(line.text)
            .font(.system(size: 12, weight: weight, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
    }
}
#endif
