import SwiftUI

/// Mock terminal content for the floating panel to sit over.
///
/// The panel's material and rim only mean anything against real content, so
/// the gallery draws something with the texture of a terminal (monospaced
/// lines of varying length and colour) rather than a flat fill.
struct GalleryTerminalBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    private let lines: [(String, Int)] = [
        ("$ swift test --filter SidebarFilter", 0),
        ("Test run started.", 1),
        ("BENCH sidebar-filter realistic workspaces=200", 2),
        ("  worstKeystroke=2.79ms typing=14.43ms matches=17", 1),
        ("✔ Suite \"SidebarFilterIndex\" passed", 3),
        ("✔ Test run with 34 tests in 4 suites passed", 3),
        ("", 1),
        ("$ git status --short", 0),
        (" M Packages/macOS/CmuxSidebar/Sources/Filter", 2),
        ("?? Packages/macOS/CmuxSidebarGallery", 4),
        ("", 1),
        ("$ ./scripts/reload.sh --tag rail", 0),
        ("==> reload succeeded in 936s", 3),
        ("", 1),
        ("$ ", 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.0)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(color(for: line.1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colorScheme == .dark
            ? Color(.sRGB, red: 0.055, green: 0.059, blue: 0.067, opacity: 1)
            : Color(.sRGB, red: 0.99, green: 0.99, blue: 0.985, opacity: 1))
    }

    private func color(for kind: Int) -> Color {
        switch kind {
        case 0: return colorScheme == .dark ? .white.opacity(0.85) : .black.opacity(0.8)
        case 2: return Color(.sRGB, red: 0.42, green: 0.62, blue: 0.95, opacity: 1)
        case 3: return Color(.sRGB, red: 0.35, green: 0.75, blue: 0.5, opacity: 1)
        case 4: return Color(.sRGB, red: 0.92, green: 0.68, blue: 0.3, opacity: 1)
        default: return colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.45)
        }
    }
}
