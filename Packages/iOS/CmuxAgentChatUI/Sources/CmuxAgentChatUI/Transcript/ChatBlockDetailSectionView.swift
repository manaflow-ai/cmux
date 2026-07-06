import SwiftUI

struct ChatBlockDetailSectionView: View {
    let section: ChatBlockDetailSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch section.style {
        case .prose:
            Text(verbatim: section.text.isEmpty ? " " : section.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .monospaced:
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: section.text.isEmpty ? " " : section.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
        }
    }
}
