#if canImport(AppKit)

internal import SwiftUI
internal import AppKit

/// A mock left/right sidebar shown beside each ``TabBarBackdropLabSample``: a
/// labeled column of placeholder rows tinted with the variant's surface color and
/// a single leading- or trailing-edge border.
struct TabBarBackdropLabSidebar: View {
    let title: String
    let surfaceColor: NSColor
    let separatorColor: NSColor
    let trailingBorder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(index == 0 ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                    .frame(height: 18)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: surfaceColor))
        .overlay(alignment: trailingBorder ? .trailing : .leading) {
            Rectangle()
                .fill(Color(nsColor: separatorColor))
                .frame(width: 1)
        }
    }
}

#endif
