import SwiftUI

/// Safari/Chrome-style downloads button for the browser omnibar. Shows a
/// popover listing recent downloads with Open / Show in Finder actions.
///
/// Everything below this view receives immutable value snapshots
/// (`BrowserDownloadRecord`) plus action closures — no `BrowserPanel` store
/// crosses the popover's `ForEach` boundary (CLAUDE.md snapshot-boundary rule).
struct BrowserDownloadsToolbarButton: View {
    let downloads: [BrowserDownloadRecord]
    let isDownloading: Bool
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let onOpen: (BrowserDownloadRecord) -> Void
    let onReveal: (BrowserDownloadRecord) -> Void
    let onClear: () -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                CmuxSystemSymbolImage(systemName: "arrow.down.circle", pointSize: iconPointSize, weight: .medium)
                if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                }
            }
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .safeHelp(String(localized: "browser.downloads.title", defaultValue: "Downloads"))
        .accessibilityLabel(String(localized: "browser.downloads.title", defaultValue: "Downloads"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BrowserDownloadsPopoverContent(
                downloads: downloads,
                onOpen: onOpen,
                onReveal: onReveal,
                onClear: onClear
            )
        }
    }
}

private struct BrowserDownloadsPopoverContent: View {
    let downloads: [BrowserDownloadRecord]
    let onOpen: (BrowserDownloadRecord) -> Void
    let onReveal: (BrowserDownloadRecord) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "browser.downloads.title", defaultValue: "Downloads"))
                    .font(.headline)
                Spacer()
                if !downloads.isEmpty {
                    Button(String(localized: "browser.downloads.clear", defaultValue: "Clear")) {
                        onClear()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if downloads.isEmpty {
                Text(String(localized: "browser.downloads.empty", defaultValue: "No recent downloads"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(downloads) { record in
                            BrowserDownloadRow(record: record, onOpen: onOpen, onReveal: onReveal)
                            if record.id != downloads.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 340)
    }
}

private struct BrowserDownloadRow: View {
    let record: BrowserDownloadRecord
    let onOpen: (BrowserDownloadRecord) -> Void
    let onReveal: (BrowserDownloadRecord) -> Void

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
            }

            Spacer(minLength: 8)

            if record.state == .saved {
                Button(String(localized: "browser.downloads.open", defaultValue: "Open")) {
                    onOpen(record)
                }
                .buttonStyle(.borderless)
                .font(.callout)

                Button {
                    onReveal(record)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "browser.downloads.showInFinder", defaultValue: "Show in Finder"))
                .accessibilityLabel(String(localized: "browser.downloads.showInFinder", defaultValue: "Show in Finder"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if record.state == .saved {
                onOpen(record)
            }
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch record.state {
        case .downloading:
            ProgressView().controlSize(.small)
        case .saved:
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
                .imageScale(.large)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
        }
    }

    private var subtitle: String {
        switch record.state {
        case .downloading:
            return String(localized: "browser.downloading", defaultValue: "Downloading...")
        case .failed:
            return String(localized: "browser.downloads.failed", defaultValue: "Failed")
        case .saved:
            if let bytes = record.byteCount, bytes > 0 {
                return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }
            return record.fileURL?.deletingLastPathComponent().lastPathComponent ?? ""
        }
    }
}
