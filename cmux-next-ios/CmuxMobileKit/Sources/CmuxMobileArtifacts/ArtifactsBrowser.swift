import Foundation

/// The browser's filter chips (SPEC 11.3), shared by the terminal and agent sessions.
public enum ArtifactFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", files = "Files", folders = "Folders", images = "Images", videos = "Videos",
         documents = "Documents", code = "Code", links = "Links"
    public var id: String { rawValue }

    public func includes(_ kind: TerminalArtifact.Kind) -> Bool {
        switch self {
        case .all: true
        case .files: ![.directory, .link].contains(kind)
        case .folders: kind == .directory
        case .images: kind == .image
        case .videos: kind == .video || kind == .audio
        case .documents: [.html, .markdown, .pdf, .text, .document].contains(kind)
        case .code: kind == .code
        case .links: kind == .link
        }
    }
}

#if os(iOS)
import CmuxMobileDesign
import SwiftUI

/// Navigation and view state of one artifacts browser (the demo driver sets it too).
@MainActor
@Observable
public final class ArtifactsBrowserState {
    public var path: [TerminalArtifact] = []
    public var filter: ArtifactFilter = .all
    public var showSource = false
    public var grid = false

    public init() {}
}

/// Everything a session referenced, filtered by chips, as a list or a
/// ChatGPT Library style grid; each item opens its best preview. Owns its
/// navigation stack (present it in a sheet).
public struct ArtifactsBrowser: View {
    let title: String
    let artifacts: [TerminalArtifact]
    let source: any ArtifactSource
    let emptyMessage: String
    @Bindable var state: ArtifactsBrowserState
    @Environment(\.dismiss) private var dismiss

    public init(title: String, artifacts: [TerminalArtifact], source: any ArtifactSource, state: ArtifactsBrowserState,
                emptyMessage: String) {
        self.title = title
        self.artifacts = artifacts
        self.source = source
        self.state = state
        self.emptyMessage = emptyMessage
    }

    private var shown: [TerminalArtifact] {
        artifacts.filter { state.filter.includes($0.kind) }.sorted { $0.order > $1.order }
    }

    private var filters: [ArtifactFilter] {
        ArtifactFilter.allCases.filter { filter in filter == .all || artifacts.contains { filter.includes($0.kind) } }
    }

    public var body: some View {
        NavigationStack(path: $state.path) {
            Group {
                if state.grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(shown) { artifact in
                                NavigationLink(value: artifact) { ArtifactTile(artifact: artifact, source: source) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                } else {
                    List {
                        ForEach(shown) { artifact in
                                NavigationLink(value: artifact) { ArtifactRow(artifact: artifact) }
                                    .contextMenu {
                                        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.reference }
                                            .tint(Color(uiColor: .systemGray))
                                    }
                            }
                    }
                    .listStyle(.plain)
                }
            }
            // One chip row above both layouts, so it sits at the same y in list and grid.
            .safeAreaInset(edge: .top, spacing: 0) {
                chips.padding(.horizontal, 20).background(.bar)
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing referenced yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text(emptyMessage))
                }
            }
            .animation(.snappy, value: state.grid)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TerminalArtifact.self) { artifact in
                ArtifactPreview(artifact: artifact, source: source, showSource: $state.showSource)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(state.grid ? "List" : "Grid", systemImage: state.grid ? "list.bullet" : "square.grid.2x2") {
                        state.grid.toggle()
                    }
                    .accessibilityIdentifier("artifacts.layout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(filters) { item in
                    let count = artifacts.filter { item.includes($0.kind) }.count
                    Button {
                        withAnimation(.snappy) { state.filter = item }
                    } label: {
                        Text(item == .all ? "All \(count)" : item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Color.primary.opacity(state.filter == item ? 0.16 : 0.06), in: .capsule)
                            // 44 pt target around the 34 pt capsule.
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.filter == item ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .trailingOverflowFade(width: 24)
        .textCase(nil)
        .foregroundStyle(.primary)
        .sensoryFeedback(.selection, trigger: state.filter)
    }
}

/// One referenced item: type glyph, name, then how it was referenced (or its path).
public struct ArtifactRow: View {
    let artifact: TerminalArtifact

    public init(artifact: TerminalArtifact) {
        self.artifact = artifact
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(artifact.kind == .directory ? Color.secondary : Color.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    if let detail = artifact.detail {
                        Text(detail).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(artifact.reference + (artifact.line.map { ":\($0)" } ?? ""))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .font(.footnote)
                .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// A 1:1 grid tile (SPEC 11.3): image thumbnails, a glyph card otherwise.
struct ArtifactTile: View {
    let artifact: TerminalArtifact
    let source: any ArtifactSource
    @State private var thumbnail: ArtifactThumbnail?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { preview }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
            // The type glyph sits in the footer, next to the name, never on the content.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: artifact.systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(artifact.name).font(.footnote).lineLimit(2)
            }
            if let detail = artifact.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: artifact) {
            guard artifact.kind != .link else { return }
            thumbnail = await ArtifactThumbnailCache.shared.thumbnail(for: artifact, source: source)
        }
    }

    /// The real thing when it renders (picture or excerpt); a link's domain; the type icon otherwise.
    @ViewBuilder private var preview: some View {
        switch thumbnail {
        case .picture(let image)?:
            Image(uiImage: image).resizable().scaledToFill()
        case .excerpt(let text)?:
            Text(text)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(TerminalArtifact.thumbnailExcerptLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .dynamicTypeSize(.large)
                .accessibilityHidden(true)
        case nil:
            if artifact.kind == .link, let host = URL(string: artifact.reference)?.host() {
                // No page fetch for a thumbnail: the domain under a link glyph.
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
                .padding(12)
                .accessibilityHidden(true)
            } else {
                Image(systemName: artifact.systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
