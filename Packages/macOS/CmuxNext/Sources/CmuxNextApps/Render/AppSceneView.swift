public import AppKit
import CmuxNextDesign
public import SwiftUI
import CmuxNextIcons

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
                AppSceneFailureRow(reason: reason, onReload: { [model] in model.reload() })
            case .disconnected(let reason):
                AppSceneFailureRow(reason: reason, symbol: "bolt.horizontal", tone: \.tertiary)
            case .loading, .ready:
                if let root = model.scene.root { AppSceneNodeView(model: model, id: root) }
            }
        }
        .environment(\.appBundleDirectory, bundleDirectory)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The error card of a failed mount: the reason in full (selectable, so it can be copied), the
/// script line it names on its own line, and Reload, which runs the saved script again.
struct AppSceneFailureRow: View {
    @Environment(\.appSceneColors) private var colors
    let reason: String
    var symbol = "exclamationmark.triangle"
    var tone: KeyPath<AppSceneColors, Color> = \.attention
    /// Nil: no Reload (a disconnected mount comes back by itself).
    var onReload: (() -> Void)?

    var body: some View {
        let failure = AppScriptFailure(reason: reason)
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Icon(symbol: symbol, size: 13)
                .foregroundStyle(colors[keyPath: tone])
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(failure.message)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let location = failure.location {
                    Text(location)
                        .font(Font(Typography.caption).monospaced())
                        .foregroundStyle(colors.tertiary)
                        .textSelection(.enabled)
                }
                if let onReload {
                    Button(AppsStrings.reload, action: onReload)
                        .buttonStyle(.link)
                        .font(Font(Typography.caption))
                        .help(AppsStrings.reloadHelp)
                }
            }
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.vertical, Metrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

