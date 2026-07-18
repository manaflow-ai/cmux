#if DEBUG
import SwiftUI

/// Maps one complete terminal transcript line into Meridian's semantic palette.
struct MeridianTerminalLineView: View {
    let line: GalleryTerminalLine

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(line.text)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(lineColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var lineColor: Color {
        switch line.tone {
        case .plain: theme.label
        case .dim: theme.secondaryLabel
        case .accent: theme.accent
        case .success: theme.done
        case .warning: theme.needsYou
        case .error: theme.failed
        }
    }
}
#endif
