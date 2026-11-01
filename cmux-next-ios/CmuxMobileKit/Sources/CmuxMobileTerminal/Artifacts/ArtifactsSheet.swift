#if os(iOS)
import SwiftUI

/// Everything the session referenced (SPEC 11.2-11.4): files, folders and
/// links parsed from the output, filtered by chips, each opening a preview.
struct ArtifactsSheet: View {
    @Bindable var model: TerminalModel
    @State private var filter: Filter = .all
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", files = "Files", folders = "Folders", images = "Images", videos = "Videos", code = "Code", links = "Links"
        var id: String { rawValue }

        func includes(_ kind: TerminalArtifact.Kind) -> Bool {
            switch self {
            case .all: true
            case .files: ![.directory, .link].contains(kind)
            case .folders: kind == .directory
            case .images: kind == .image
            case .videos: kind == .video
            case .code: [.code, .html, .markdown, .text].contains(kind)
            case .links: kind == .link
            }
        }

        /// The empty state's title: the generic one only for All (P3).
        var emptyTitle: String {
            switch self {
            case .all: "Nothing referenced"
            case .files: "No files"
            case .folders: "No folders"
            case .images: "No images"
            case .videos: "No videos"
            case .code: "No code"
            case .links: "No links"
            }
        }
    }

    private var shown: [TerminalArtifact] {
        model.artifacts.filter { filter.includes($0.kind) }.sorted { $0.order > $1.order }
    }

    private func count(_ item: Filter) -> Int {
        model.artifacts.filter { item.includes($0.kind) }.count
    }

    /// All, then every filter with items (and the selected one, so it never
    /// vanishes under the finger).
    private var chipFilters: [Filter] {
        Filter.allCases.filter { $0 == .all || $0 == filter || count($0) > 0 }
    }

    var body: some View {
        NavigationStack(path: $model.artifactPath) {
            VStack(spacing: 0) {
                // 8 pt under the Done button (R1-7, R2-7): the bar's bottom
                // margin is 5 pt deeper than its buttons, so the chips go up by it.
                chips
                    .padding(.top, -5)
                    .padding(.bottom, 4)
                List {
                    ForEach(shown) { artifact in
                        NavigationLink(value: artifact) { ArtifactRow(artifact: artifact) }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(filter.emptyTitle, systemImage: "doc.text.magnifyingglass",
                                               description: Text("Files, folders and links that appear in the terminal show up here."))
                    }
                }
            }
            .navigationTitle("Files and Links")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TerminalArtifact.self) { artifact in
                ArtifactPreview(artifact: artifact, source: model.artifactSource, showSource: $model.previewShowsSource)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    /// Directly under the title, edge to edge, scrolling with a 16 pt
    /// leading inset (P2). Every chip shows its count.
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chipFilters) { item in
                    let selected = filter == item
                    Button {
                        withAnimation(.snappy) { filter = item }
                    } label: {
                        Text("\(item.rawValue) \(count(item))")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.primary.opacity(selected ? 0.16 : 0.06), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("artifacts.filter.\(item.rawValue.lowercased())")
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
        .foregroundStyle(.primary)
        .sensoryFeedback(.selection, trigger: filter)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
