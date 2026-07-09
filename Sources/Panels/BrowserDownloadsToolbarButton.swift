import SwiftUI
import CmuxUpdater
import CmuxSettings
import CmuxBrowserUI

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
    @State private var seenIDs: Set<String> = []

    private var completedCount: Int {
        downloads.reduce(0) { $0 + ($1.state == .saved ? 1 : 0) }
    }

    /// Downloads not yet viewed in the popover — drives the notification bubble.
    private var unseenCount: Int {
        downloads.reduce(0) { $0 + (seenIDs.contains($1.id) ? 0 : 1) }
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                // Monochrome to match the rest of the omnibar — motion carries
                // the state instead of a persistent accent tint: a spinner while
                // a download is in flight, and a bounce each time one lands.
                // (A repeating `.bounce` would need macOS 15; plain SF Symbol so
                // the discrete `.bounce` applies — CmuxSystemSymbolImage is
                // NSImage-backed and ignores `.symbolEffect`.)
                Group {
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: iconPointSize, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .symbolEffect(.bounce, value: completedCount)
                    }
                }
                .frame(width: hitSize, height: hitSize, alignment: .center)

                // Notification bubble: count of downloads not yet viewed. Clears
                // when the popover is opened (see onChange below).
                if unseenCount > 0 {
                    Text(unseenCount > 99 ? "99+" : "\(unseenCount)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.red))
                        .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 6, y: -4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: unseenCount)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .safeHelp(String(localized: "browser.downloads.title", defaultValue: "Downloads"))
        .accessibilityLabel(String(localized: "browser.downloads.title", defaultValue: "Downloads"))
        .onChange(of: isPresented) { _, presented in
            if presented {
                seenIDs = Set(downloads.map(\.id))
            }
        }
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
