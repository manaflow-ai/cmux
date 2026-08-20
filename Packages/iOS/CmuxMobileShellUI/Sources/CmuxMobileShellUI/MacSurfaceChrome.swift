import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Rounded-rect kind glyph shared by surface headers, cards, and rows.
struct MacSurfaceIconBadge: View {
    let kind: MobileSurfacePreview.Kind
    var side: CGFloat = 34

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: side * 0.52, weight: .medium))
            .foregroundStyle(kind.tint)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// Compact chrome row above a native Mac-surface renderer.
///
/// Keeps every surface's top edge consistent: kind badge, surface title,
/// contextual subtitle, and an optional surface-specific accessory.
struct MacSurfaceHeader<Accessory: View>: View {
    let kind: MobileSurfacePreview.Kind
    let title: String
    let subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            MacSurfaceIconBadge(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

extension MacSurfaceHeader where Accessory == EmptyView {
    init(
        kind: MobileSurfacePreview.Kind,
        title: String,
        subtitle: String?
    ) {
        self.init(kind: kind, title: title, subtitle: subtitle) { EmptyView() }
    }

    /// Convenience initializer for file-backed surfaces: derives the subtitle
    /// from the file path (the file name when the title doesn't already show
    /// it, otherwise the parent directory name so a duplicated line never
    /// appears).
    init(
        kind: MobileSurfacePreview.Kind,
        title: String,
        path: String
    ) {
        self.init(kind: kind, title: title, subtitle: Self.fileSubtitle(title: title, path: path))
    }

    private static func fileSubtitle(title: String, path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty else { return nil }
        if title != fileName { return fileName }
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent
    }
}

/// Centered inline state (loading complement, error, empty) for surfaces.
struct MacSurfaceMessageView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Label(
                        L10n.string("mobile.surface.retry", defaultValue: "Retry"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
