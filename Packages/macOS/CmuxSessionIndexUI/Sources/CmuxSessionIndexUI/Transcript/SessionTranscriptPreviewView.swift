public import SwiftUI
public import CmuxSessionIndex
public import CmuxFoundation

/// The transcript preview popover content: a header (agent icon, title, cwd, close) over
/// a scrollable transcript, with a bottom-trailing resize grip and Escape-to-dismiss.
///
/// All localization and presentation resolution happens app-side and is injected: the
/// agent icon's `assetName`/`systemImageName`, the `title`/`cwdLabel`, the
/// ``SessionTranscriptPreviewStrings`` (status text + per-role labels), and the
/// `ripgrepScanner` plus loader markers. The view loads the transcript through
/// `SessionTranscriptLoader` and renders `SessionTranscriptDisplayRow`s; it never reaches
/// into app-side `SessionEntry`/`SessionAgent` presentation extensions.
public struct SessionTranscriptPreviewView: View {
    private let entry: SessionEntry
    private let assetName: String?
    private let systemImageName: String?
    private let title: String
    private let cwdLabel: String?
    private let strings: SessionTranscriptPreviewStrings
    private let ripgrepScanner: RipgrepFileScanner
    private let truncatedMarker: String
    private let largeRecordMarker: String
    private let layout: SessionTranscriptPreviewLayout
    private let sizeModel: SessionTranscriptPopoverSizeModel
    private let onResize: (CGSize) -> Void
    private let onDismiss: () -> Void

    @State private var loadState: SessionTranscriptPreviewState = .loading
    @State private var closeIsHovered = false

    /// Creates a transcript preview from app-resolved presentation values and seams.
    /// - Parameters:
    ///   - entry: The session whose transcript loads here (drives the loader + `.task` id).
    ///   - assetName: The agent icon's asset-catalog name (main bundle), or `nil` for a symbol.
    ///   - systemImageName: The SF Symbol fallback for the agent icon.
    ///   - title: The already-resolved session display title.
    ///   - cwdLabel: The already-resolved working-directory label, or `nil` to hide it.
    ///   - strings: App-resolved status strings and per-role labels.
    ///   - ripgrepScanner: Scanner injected into `SessionTranscriptLoader`.
    ///   - truncatedMarker: App-localized "Preview truncated" loader marker.
    ///   - largeRecordMarker: App-localized "Large transcript record omitted" loader marker.
    ///   - layout: Sizing bounds for the resize clamp (defaults to `.standard`).
    ///   - sizeModel: The shared live popover size.
    ///   - onResize: Reports a proposed size from the resize grip (host clamps via `layout`).
    ///   - onDismiss: Invoked on close tap or Escape.
    public init(
        entry: SessionEntry,
        assetName: String?,
        systemImageName: String?,
        title: String,
        cwdLabel: String?,
        strings: SessionTranscriptPreviewStrings,
        ripgrepScanner: RipgrepFileScanner,
        truncatedMarker: String,
        largeRecordMarker: String,
        layout: SessionTranscriptPreviewLayout = .standard,
        sizeModel: SessionTranscriptPopoverSizeModel,
        onResize: @escaping (CGSize) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entry = entry
        self.assetName = assetName
        self.systemImageName = systemImageName
        self.title = title
        self.cwdLabel = cwdLabel
        self.strings = strings
        self.ripgrepScanner = ripgrepScanner
        self.truncatedMarker = truncatedMarker
        self.largeRecordMarker = largeRecordMarker
        self.layout = layout
        self.sizeModel = sizeModel
        self.onResize = onResize
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: sizeModel.size.width, height: sizeModel.size.height)
        .overlay(alignment: .bottomTrailing) {
            SessionTranscriptResizeHandle(
                size: sizeModel.size,
                resizeHelp: strings.resize,
                onResize: onResize
            )
        }
        .task(id: entry.id) {
            await loadTranscript()
        }
        .background(
            EscapeKeyCatcher { onDismiss() }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIconImage(assetName: assetName, systemImageName: systemImageName, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cwdLabel {
                    Text(cwdLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(closeIsHovered ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(closeIsHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .onHover { closeIsHovered = $0 }
                .onTapGesture {
                    onDismiss()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(strings.close))
                .accessibilityAddTraits(.isButton)
                .help(strings.close)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingStatusRow
        case .missingFile:
            statusRow(
                systemImage: "doc.badge.questionmark",
                text: strings.noFile
            )
        case .failed:
            statusRow(
                systemImage: "exclamationmark.triangle.fill",
                text: strings.error
            )
        case .loaded(let turns):
            if turns.isEmpty {
                statusRow(
                    systemImage: "text.bubble",
                    text: strings.empty
                )
            } else {
                SessionTranscriptVirtualizedList(rows: turns, roleLabel: strings.roleLabel)
            }
        }
    }

    private var loadingStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(strings.loading)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor
    private func loadTranscript() async {
        loadState = .loading
        // The preview markers are resolved app-side so they pick up the app
        // bundle's localizations (the package bundle lacks these keys).
        let loader = SessionTranscriptLoader(
            ripgrepScanner: ripgrepScanner,
            truncatedMarker: truncatedMarker,
            largeRecordMarker: largeRecordMarker
        )
        do {
            let turns = try await loader.load(entry: entry)
            guard !Task.isCancelled else { return }
            loadState = .loaded(SessionTranscriptDisplayRow.rows(from: turns))
        } catch SessionTranscriptLoadError.missingFile {
            guard !Task.isCancelled else { return }
            loadState = .missingFile
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }
}
