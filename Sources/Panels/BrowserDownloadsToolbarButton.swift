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

    private var hasDownloads: Bool { !downloads.isEmpty }
    private var completedCount: Int {
        downloads.reduce(0) { $0 + ($1.state == .saved ? 1 : 0) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                // Plain SF Symbol (not CmuxSystemSymbolImage) so `.symbolEffect`
                // animations apply: a continuous bounce while a download is in
                // flight, and a one-shot bounce each time one completes.
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: iconPointSize, weight: .medium))
                    .foregroundStyle(isDownloading || hasDownloads ? Color.accentColor : Color.primary)
                    .symbolEffect(.bounce, options: .repeating, isActive: isDownloading)
                    .symbolEffect(.bounce, value: completedCount)
                    .frame(width: hitSize, height: hitSize, alignment: .center)

                if hasDownloads {
                    Text(downloads.count > 99 ? "99+" : "\(downloads.count)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.accentColor))
                        .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 6, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: downloads.count)
            .animation(.easeInOut(duration: 0.2), value: isDownloading)
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
