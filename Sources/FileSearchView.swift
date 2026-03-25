import SwiftUI
import AppKit

/// View model for file search across workspace directories.
@MainActor
final class FileSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FileSearchResult] = []
    @Published var isSearching: Bool = false
    var rootPaths: [String] = []
    var onOpenFile: ((String) -> Void)?

    private var searchTask: Task<Void, Never>?

    func search() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask?.cancel()
        isSearching = true
        let paths = rootPaths
        let searchQuery = query.lowercased()

        searchTask = Task {
            var found: [FileSearchResult] = []
            for rootPath in paths {
                let rootName = (rootPath as NSString).lastPathComponent
                await searchDirectory(
                    at: rootPath,
                    relativeTo: "",
                    rootPath: rootPath,
                    rootName: rootName,
                    query: searchQuery,
                    results: &found,
                    maxResults: 200
                )
                if found.count >= 200 { break }
            }
            if !Task.isCancelled {
                results = found
                isSearching = false
            }
        }
    }

    private func searchDirectory(
        at path: String,
        relativeTo parent: String,
        rootPath: String,
        rootName: String,
        query: String,
        results: inout [FileSearchResult],
        maxResults: Int
    ) async {
        guard results.count < maxResults else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }

        for entry in entries.sorted() {
            if Task.isCancelled || results.count >= maxResults { return }
            if entry == ".git" { continue }

            let relativePath = parent.isEmpty ? entry : parent + "/" + entry
            let fullPath = (path as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            if entry.lowercased().contains(query) {
                results.append(FileSearchResult(
                    name: entry,
                    relativePath: relativePath,
                    absolutePath: fullPath,
                    rootName: rootName,
                    isDirectory: isDir.boolValue
                ))
            }

            if isDir.boolValue {
                // Skip heavy directories
                let skip: Set<String> = ["node_modules", ".build", "DerivedData", "__pycache__", "dist", ".next", "Pods", "target", "zig-out", ".zig-cache"]
                if !skip.contains(entry) {
                    await searchDirectory(
                        at: fullPath,
                        relativeTo: relativePath,
                        rootPath: rootPath,
                        rootName: rootName,
                        query: query,
                        results: &results,
                        maxResults: maxResults
                    )
                }
            }
        }
    }
}

struct FileSearchResult: Identifiable {
    let id = UUID()
    let name: String
    let relativePath: String
    let absolutePath: String
    let rootName: String
    let isDirectory: Bool
}

/// NSTextField wrapper that properly claims and holds first responder from terminals.
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onChanged: () -> Void
    var shouldFocus: Bool = false

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if shouldFocus, !context.coordinator.hasFocused, let window = nsView.window {
            context.coordinator.hasFocused = true
            window.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarSearchField
        var hasFocused = false
        init(_ parent: SidebarSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onChanged()
        }
    }
}

struct FileSearchView: View {
    @ObservedObject var viewModel: FileSearchViewModel
    @State private var shouldFocusSearch = false

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                SidebarSearchField(
                    text: $viewModel.query,
                    placeholder: String(localized: "fileSearch.placeholder", defaultValue: "Search files..."),
                    onChanged: { viewModel.search() },
                    shouldFocus: shouldFocusSearch
                )
                .frame(height: 20)

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                        viewModel.results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            Divider()

            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.top, 20)
                Spacer()
            } else if viewModel.results.isEmpty && !viewModel.query.isEmpty {
                Text(String(localized: "fileSearch.noResults", defaultValue: "No files found"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.results) { result in
                            FileSearchResultRow(result: result) {
                                viewModel.onOpenFile?(result.absolutePath)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            // Delay focus to next runloop so the view is mounted
            DispatchQueue.main.async { shouldFocusSearch = true }
        }
    }
}

struct FileSearchResultRow: View {
    let result: FileSearchResult
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(name: result.name, isDirectory: result.isDirectory, isExpanded: false)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(result.relativePath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
    }
}
