public import AppKit
import CmuxNextDesign
public import SwiftUI
import CmuxNextIcons

extension EnvironmentValues {
    /// The mounted app's bundle directory (resolves `Image(src)` paths).
    @Entry var appBundleDirectory: URL?
    /// The mount's client's decoded bundle images (``AppMount/bundleImages``) for the scene's
    /// `Image(src)` nodes. ``AppSceneView``, the one root of a scene's node views, sets it; nil elsewhere.
    @Entry var appBundleImages: AppBundleImageCache?
}

/// Renders one mounted contribution's scene natively (spec section 7.1).
/// Loading shows nothing (no spinner flash for a fast first render); a
/// failure shows a quiet error row with the reason.
public struct AppSceneView: View {
    let model: AppSceneModel
    let bundleDirectory: URL?
    let bundleImages: AppBundleImageCache

    /// The scene of `mount`, its images from the mount's bundle (decoded once per client).
    public init(mount: AppMount) {
        model = mount.model
        bundleDirectory = mount.bundleDirectory
        bundleImages = mount.bundleImages
    }

    public var body: some View {
        Group {
            switch model.status {
            case .failed(let reason):
                AppSceneFailureRow(reason: reason)
            case .disconnected(let reason):
                AppSceneFailureRow(reason: reason, symbol: "bolt.horizontal", tone: \.tertiary)
            case .loading, .ready:
                if let root = model.scene.root { AppSceneNodeView(model: model, id: root) }
            }
        }
        .environment(\.appBundleDirectory, bundleDirectory)
        .environment(\.appBundleImages, bundleImages)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The error row of a failed mount.
struct AppSceneFailureRow: View {
    @Environment(\.appSceneColors) private var colors
    let reason: String
    var symbol = "exclamationmark.triangle"
    var tone: KeyPath<AppSceneColors, Color> = \.attention

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Icon(symbol: symbol, size: 13)
                .foregroundStyle(colors[keyPath: tone])
            Text(reason)
                .font(Font(Typography.caption))
                .foregroundStyle(colors.secondary)
                .lineLimit(3)
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.vertical, Metrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

