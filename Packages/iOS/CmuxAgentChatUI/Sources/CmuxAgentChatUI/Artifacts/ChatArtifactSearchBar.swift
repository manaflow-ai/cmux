import SwiftUI

/// Inline in-file search controls for the currently loaded artifact text.
struct ChatArtifactSearchBar: View {
    @Binding var query: String
    let summary: ChatArtifactSearchSummary
    let isStillLoading: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                searchField

                if !query.isEmpty {
                    Text(verbatim: "\(summary.currentPosition)/\(summary.matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                }
                .disabled(query.isEmpty || summary.matchCount == 0)
                .accessibilityLabel(String(
                    localized: "chat.artifact.search.previous",
                    defaultValue: "Previous match",
                    bundle: .module
                ))

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                }
                .disabled(query.isEmpty || summary.matchCount == 0)
                .accessibilityLabel(String(
                    localized: "chat.artifact.search.next",
                    defaultValue: "Next match",
                    bundle: .module
                ))

                Button {
                    isSearchFieldFocused = false
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel(String(
                    localized: "chat.artifact.search.close",
                    defaultValue: "Close search",
                    bundle: .module
                ))
            }
            .buttonStyle(.plain)

            if isStillLoading, !query.isEmpty {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(
                        localized: "chat.artifact.search.still_loading",
                        defaultValue: "Still loading",
                        bundle: .module
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear {
            isSearchFieldFocused = true
        }
        .onDisappear {
            isSearchFieldFocused = false
        }
    }

    @ViewBuilder
    private var searchField: some View {
        #if os(iOS)
        baseSearchField
            .textInputAutocapitalization(.never)
        #else
        baseSearchField
        #endif
    }

    private var baseSearchField: some View {
        TextField(
            String(
                localized: "chat.artifact.search.placeholder",
                defaultValue: "Find in file",
                bundle: .module
            ),
            text: $query
        )
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .focused($isSearchFieldFocused)
        .onSubmit {
            isSearchFieldFocused = false
            onNext()
        }
    }
}
