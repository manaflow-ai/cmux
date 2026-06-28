public import SwiftUI

/// The browser top-chrome leading navigation bar: back, forward, and the
/// reload/stop button (with its reload/hard-refresh context menu) plus the
/// inline downloading indicator.
///
/// Renders from a ``BrowserToolbarSnapshot`` and routes every tap through
/// ``BrowserToolbarActions``; the panel mutations and `#if DEBUG` logs live on
/// the app-side forwarder that builds those values.
public struct BrowserToolbarView: View {
    private let snapshot: BrowserToolbarSnapshot
    private let actions: BrowserToolbarActions

    /// Creates the navigation bar from a snapshot and action bundle.
    public init(snapshot: BrowserToolbarSnapshot, actions: BrowserToolbarActions) {
        self.snapshot = snapshot
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.onBack) {
                Image(systemName: "chevron.left")
                    .cmuxSymbolRasterSize(snapshot.navigationIconFontSize, weight: .medium)
                    .frame(width: snapshot.buttonHitSize, height: snapshot.buttonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!snapshot.canGoBack)
            .opacity(snapshot.canGoBack ? 1.0 : 0.4)
            .safeHelp(snapshot.goBackHelp)

            Button(action: actions.onForward) {
                Image(systemName: "chevron.right")
                    .cmuxSymbolRasterSize(snapshot.navigationIconFontSize, weight: .medium)
                    .frame(width: snapshot.buttonHitSize, height: snapshot.buttonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!snapshot.canGoForward)
            .opacity(snapshot.canGoForward ? 1.0 : 0.4)
            .safeHelp(snapshot.goForwardHelp)

            Button(action: actions.onReloadOrStop) {
                Image(systemName: snapshot.isLoading ? "xmark" : "arrow.clockwise")
                    .cmuxSymbolRasterSize(snapshot.navigationIconFontSize, weight: .medium)
                    .frame(width: snapshot.buttonHitSize, height: snapshot.buttonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .contextMenu {
                Button(snapshot.reloadLabel) {
                    actions.onReload()
                }
                Button(snapshot.hardRefreshLabel) {
                    actions.onHardRefresh()
                }
            }
            .safeHelp(snapshot.reloadOrStopHelp)

            if snapshot.isDownloading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(snapshot.downloadingText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .safeHelp(snapshot.downloadInProgressHelp)
            }
        }
    }
}
