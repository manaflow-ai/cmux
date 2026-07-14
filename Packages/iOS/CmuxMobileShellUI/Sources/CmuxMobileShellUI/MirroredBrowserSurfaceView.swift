import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI
#if canImport(UIKit)
import CoreGraphics
#endif

/// Full-pane, explicitly view-only rendering of a Mac browser surface.
struct MirroredBrowserSurfaceView: View {
    let surfaceID: String
    let fallbackTitle: String
    let isPreviewSupported: Bool
    let previewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    private let imageDecoder = BrowserPreviewImageDecoder()
    @State private var image: CGImage?
    @State private var frameTitle: String?
    @State private var frameURL: String?

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
                guard let decoded = await imageDecoder.decode(
                    update.imageData,
                    maxPixelDimension: 1_600
                ), !Task.isCancelled else { continue }
                image = decoded
                frameTitle = update.title
                frameURL = update.url
            }
        }
        .accessibilityIdentifier("MobileMirroredBrowserView-\(surfaceID)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    browserTitle
                    Spacer(minLength: 8)
                    viewingAffordance
                }
                VStack(alignment: .leading, spacing: 5) {
                    browserTitle
                    viewingAffordance
                }
            }
            if let url = frameURL, !url.isEmpty {
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
        } else if let image {
            Image(decorative: image, scale: 1)
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

    private var browserTitle: some View {
        Label(resolvedTitle, systemImage: "safari.fill")
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var viewingAffordance: some View {
        Label(
            L10n.string("mobile.browser.mirrored.viewing", defaultValue: "Viewing Mac browser"),
            systemImage: "eye"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var resolvedTitle: String {
        guard let title = frameTitle, !title.isEmpty else { return fallbackTitle }
        return title
    }
}
