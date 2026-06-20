#if canImport(AppKit)

internal import SwiftUI

/// The mock window titlebar shown above each ``TabBarBackdropLabSample``: traffic
/// lights, a workspace label, and a separator, tinted with the variant's resolved
/// surface and separator colors.
struct TabBarBackdropLabTitlebar: View {
    let variant: TabBarBackdropLabVariant
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Color.red.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.yellow.opacity(0.75)).frame(width: 8, height: 8)
                Circle().fill(Color.green.opacity(0.75)).frame(width: 8, height: 8)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .background(Color(nsColor: variant.surfaceColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: variant.separatorColor))
                .frame(height: 1)
        }
    }
}

#endif
