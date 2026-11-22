public import AppKit
import CmuxNextDesign
public import SwiftUI

extension EnvironmentValues {
    /// The mounted app's bundle directory (resolves `Image(src)` paths).
    @Entry var appBundleDirectory: URL?
}

/// Renders one mounted contribution's scene natively (spec section 7.1).
/// Loading shows nothing (no spinner flash for a fast first render); a
/// failure shows a quiet error row with the reason.
public struct AppSceneView: View {
    let model: AppSceneModel
    let bundleDirectory: URL?

    public init(model: AppSceneModel, bundleDirectory: URL? = nil) {
        self.model = model
        self.bundleDirectory = bundleDirectory
    }

    public var body: some View {
        Group {
            switch model.status {
            case .failed(let reason):
                AppSceneFailureRow(reason: reason)
            case .loading, .ready:
                if let root = model.scene.root { AppSceneNodeView(model: model, id: root) }
            }
        }
        .environment(\.appBundleDirectory, bundleDirectory)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The error row of a failed mount.
struct AppSceneFailureRow: View {
    @Environment(\.appSceneColors) private var colors
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(colors.attention)
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

