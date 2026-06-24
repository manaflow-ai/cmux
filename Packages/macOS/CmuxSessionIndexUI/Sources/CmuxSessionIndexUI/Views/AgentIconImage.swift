public import SwiftUI

/// The brand mark for a session's agent, rendered at a fixed square size.
///
/// Resolves to the agent's asset-catalog image when `assetName` is present, otherwise
/// falls back to an SF Symbol (`systemImageName`, or `person.crop.circle` when nil).
///
/// Asset seam: `assetName` values (e.g. `"AgentIcons/Claude"`) live in the host app's
/// asset catalog, so `Image(_:)` resolves them from the main bundle, not this package's
/// `Bundle.module`. Callers pass the already-resolved presentation values
/// (`SessionAgent.assetName` / `SessionAgent.systemImageName`) so this view stays a pure
/// leaf with no dependency on the app-side presentation extension.
public struct AgentIconImage: View, Equatable {
    private let assetName: String?
    private let systemImageName: String?
    private let size: CGFloat

    /// Creates an agent icon from already-resolved presentation values.
    /// - Parameters:
    ///   - assetName: The asset-catalog image name in the main bundle, or `nil` to use a symbol.
    ///   - systemImageName: The SF Symbol fallback name; `person.crop.circle` is used when `nil`.
    ///   - size: The square edge length, in points.
    public init(assetName: String?, systemImageName: String?, size: CGFloat) {
        self.assetName = assetName
        self.systemImageName = systemImageName
        self.size = size
    }

    public var body: some View {
        if let assetName {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: systemImageName ?? "person.crop.circle")
                .font(.system(size: max(size - 2, 10), weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
