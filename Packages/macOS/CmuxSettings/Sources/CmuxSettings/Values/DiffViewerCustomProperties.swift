import Foundation

/// Validated color overrides for the diff viewer's supported CSS properties.
public struct DiffViewerCustomProperties: Equatable, Sendable {
    /// Supported property names mapped to lowercase six-digit hex colors.
    public let values: [String: String]

    /// Resolves settings layers in priority order, keeping the first valid value per property.
    ///
    /// Invalid entries are ignored so a lower-priority layer can supply a valid value.
    /// - Parameter layers: Parsed `diffViewer.cssVariables` objects, highest priority first.
    public init(layers: [[String: Any]]) {
        var resolved: [String: String] = [:]
        for layer in layers {
            for (name, rawValue) in layer where resolved[name] == nil {
                guard Self.allowedNames.contains(name),
                      let rawColor = rawValue as? String else { continue }
                let color = rawColor.trimmingCharacters(in: .whitespacesAndNewlines)
                guard color.utf8.count == 7,
                      color.first == "#",
                      color.utf8.dropFirst().allSatisfy({
                          (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                      }) else { continue }
                resolved[name] = color.lowercased()
            }
        }
        values = resolved
    }

    private static let allowedNames: Set<String> = [
        "--cmux-diff-accent",
        "--cmux-diff-error",
        "--cmux-diff-renamed-light",
        "--cmux-diff-renamed-dark",
        "--cmux-diff-addition-fg-light",
        "--cmux-diff-addition-fg-dark",
        "--cmux-diff-deletion-fg-light",
        "--cmux-diff-deletion-fg-dark"
    ]
}
