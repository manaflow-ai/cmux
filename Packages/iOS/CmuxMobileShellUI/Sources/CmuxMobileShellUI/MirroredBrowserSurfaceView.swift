import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-pane, explicitly view-only rendering of a Mac browser surface.
struct MirroredBrowserSurfaceView: View {
    let surfaceID: String
    let fallbackTitle: String
    let isPreviewSupported: Bool
    let previewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    @State private var frame: MobileBrowserPreviewFrame?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            snapshot
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: surfaceID) {
            guard isPreviewSupported else { return }
            for await update in previewUpdates(surfaceID, .full) {
                guard !Task.isCancelled else { return }
                frame = update
            }
        }
        .accessibilityIdentifier("MobileMirroredBrowserView-\(surfaceID)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "safari.fill")
                    .foregroundStyle(.tint)
                Text(resolvedTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Label(
                    L10n.string("mobile.browser.mirrored.viewing", defaultValue: "Viewing Mac browser"),
                    systemImage: "eye"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            if let url = frame?.url, !url.isEmpty {
                Text(url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var snapshot: some View {
        #if canImport(UIKit)
        if !isPreviewSupported {
            ContentUnavailableView(
                L10n.string("mobile.browser.mirrored.unavailable", defaultValue: "Browser preview unavailable"),
                systemImage: "safari",
                description: Text(
                    L10n.string(
                        "mobile.browser.mirrored.unavailable.message",
                        defaultValue: "Update cmux on this Mac to view its browser."
                    )
                )
            )
        } else if let frame, let image = UIImage(data: frame.imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var resolvedTitle: String {
        guard let title = frame?.title, !title.isEmpty else { return fallbackTitle }
        return title
    }
}
