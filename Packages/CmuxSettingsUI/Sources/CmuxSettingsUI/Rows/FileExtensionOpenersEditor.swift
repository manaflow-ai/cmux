import CmuxSettings
import SwiftUI

@MainActor
public struct FileExtensionOpenersEditor: View {
    @Binding private var openers: [String: FileExtensionOpenBehavior]
    @State private var draftExtension = ""
    @State private var showsAllExtensions = false
    @State private var normalizedOpenersCache: [String: FileExtensionOpenBehavior]
    @State private var sortedExtensionCache: [String]

    private static let initiallyVisibleExtensionLimit = 32

    public init(openers: Binding<[String: FileExtensionOpenBehavior]>) {
        let normalized = Self.normalizedOpeners(openers.wrappedValue)
        self._openers = openers
        self._normalizedOpenersCache = State(initialValue: normalized)
        self._sortedExtensionCache = State(initialValue: Self.sortedExtensions(from: normalized))
    }

    public var body: some View {
        let extensions = sortedExtensionCache

        VStack(alignment: .leading, spacing: 0) {
            SettingsCardRow(
                configurationReview: .json("app.fileExtensionOpeners"),
                String(localized: "settings.app.fileExtensionOpeners", defaultValue: "File Extension Openers"),
                subtitle: String(localized: "settings.app.fileExtensionOpeners.subtitle", defaultValue: "Add any file extension and choose whether Cmd-click opens it in preview, browser, Markdown viewer, preferred editor, or system default. HTML opens in the cmux browser by default.")
            ) {
                HStack(spacing: 6) {
                    TextField(
                        String(localized: "settings.app.fileExtensionOpeners.addPlaceholder", defaultValue: "html"),
                        text: $draftExtension
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 78)

                    Button {
                        addDraftExtension()
                    } label: {
                        Label(String(localized: "settings.app.fileExtensionOpeners.add", defaultValue: "Add"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(normalizedDraftExtension == nil)
                }
            }

            if extensions.isEmpty {
                SettingsCardDivider()
                SettingsCardNote(String(localized: "settings.app.fileExtensionOpeners.empty", defaultValue: "No extension overrides. Cmd-click falls back to the supported-file and Markdown settings."))
            } else {
                ForEach(visibleExtensions(from: extensions), id: \.self) { fileExtension in
                    SettingsCardDivider()
                    openerRow(fileExtension)
                }

                if shouldShowExtensionLimitToggle(for: extensions) {
                    SettingsCardDivider()
                    extensionLimitToggleRow()
                }
            }
        }
        .onChange(of: openers) { _, newValue in
            refreshCaches(for: newValue)
        }
    }

    private var normalizedDraftExtension: String? {
        FileExtensionOpenBehavior.normalizedExtension(draftExtension)
    }

    private func visibleExtensions(from extensions: [String]) -> [String] {
        guard !showsAllExtensions, extensions.count > Self.initiallyVisibleExtensionLimit else {
            return extensions
        }
        return Array(extensions.prefix(Self.initiallyVisibleExtensionLimit))
    }

    private func shouldShowExtensionLimitToggle(for extensions: [String]) -> Bool {
        extensions.count > Self.initiallyVisibleExtensionLimit
    }

    private func extensionLimitToggleRow() -> some View {
        HStack(spacing: 12) {
            Text(String(localized: "settings.app.fileExtensionOpeners.limitedNote", defaultValue: "Showing fewer rows keeps Settings responsive. Use cmux.json for bulk changes."))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button {
                showsAllExtensions.toggle()
            } label: {
                Text(
                    showsAllExtensions
                        ? String(localized: "settings.app.fileExtensionOpeners.showFewer", defaultValue: "Show Fewer")
                        : String(localized: "settings.app.fileExtensionOpeners.showAll", defaultValue: "Show All")
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openerRow(_ fileExtension: String) -> some View {
        HStack(spacing: 12) {
            Text(".\(fileExtension)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)

            Picker(
                "",
                selection: Binding(
                    get: { normalizedOpenersCache[fileExtension] ?? .automatic },
                    set: { setBehavior($0, for: fileExtension) }
                )
            ) {
                ForEach(FileExtensionOpenBehavior.allCases) { behavior in
                    Text(displayName(for: behavior)).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 170, alignment: .trailing)

            Button {
                remove(fileExtension)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(String(localized: "settings.app.fileExtensionOpeners.remove", defaultValue: "Remove extension opener"))
            .accessibilityLabel(String(localized: "settings.app.fileExtensionOpeners.remove", defaultValue: "Remove extension opener"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addDraftExtension() {
        guard let normalized = normalizedDraftExtension else { return }
        var next = normalizedOpenersCache
        if next[normalized] == nil {
            next[normalized] = .cmuxPreview
        }
        applyOpeners(next)
        draftExtension = ""
    }

    private func setBehavior(_ behavior: FileExtensionOpenBehavior, for fileExtension: String) {
        guard let normalized = FileExtensionOpenBehavior.normalizedExtension(fileExtension) else { return }
        var next = normalizedOpenersCache
        next[normalized] = behavior
        applyOpeners(next)
    }

    private func remove(_ fileExtension: String) {
        guard let normalized = FileExtensionOpenBehavior.normalizedExtension(fileExtension) else { return }
        var next = normalizedOpenersCache
        next.removeValue(forKey: normalized)
        applyOpeners(next)
    }

    private func applyOpeners(_ value: [String: FileExtensionOpenBehavior]) {
        refreshCaches(for: value)
        openers = value
    }

    private func refreshCaches(for value: [String: FileExtensionOpenBehavior]) {
        let normalized = Self.normalizedOpeners(value)
        normalizedOpenersCache = normalized
        sortedExtensionCache = Self.sortedExtensions(from: normalized)
    }

    private static func sortedExtensions(from value: [String: FileExtensionOpenBehavior]) -> [String] {
        value.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func normalizedOpeners(_ value: [String: FileExtensionOpenBehavior]) -> [String: FileExtensionOpenBehavior] {
        var normalized: [String: FileExtensionOpenBehavior] = [:]
        for (rawExtension, behavior) in value {
            guard let normalizedExtension = FileExtensionOpenBehavior.normalizedExtension(rawExtension) else { continue }
            normalized[normalizedExtension] = behavior
        }
        return normalized
    }

    private func displayName(for behavior: FileExtensionOpenBehavior) -> String {
        switch behavior {
        case .automatic:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.automatic", defaultValue: "Automatic")
        case .cmuxPreview:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.cmuxPreview", defaultValue: "cmux Preview")
        case .markdownViewer:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.markdownViewer", defaultValue: "Markdown Viewer")
        case .cmuxBrowser:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.cmuxBrowser", defaultValue: "cmux Browser")
        case .preferredEditor:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.preferredEditor", defaultValue: "Preferred Editor")
        case .systemDefault:
            return String(localized: "settings.app.fileExtensionOpeners.behavior.systemDefault", defaultValue: "System Default")
        }
    }
}
