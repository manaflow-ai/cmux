#if canImport(AppKit)
#if DEBUG

public import SwiftUI

/// The File Explorer Style debug panel: a radio list that selects the file
/// explorer's visual style and previews the selected style's layout metrics.
///
/// The view is byte-faithful to the panel that previously lived in the app
/// target. It reads and writes the shared `fileExplorer.style` `@AppStorage`
/// integer directly (the same Defaults key the running outline view reads), so
/// the wire/Defaults contract is unchanged.
///
/// Two things are irreducibly app-coupled and injected:
///
/// - ``options``: the ordered style rows. The source `FileExplorerStyle` enum
///   lives in the app target and carries the production layout metrics, so the
///   app snapshots each style into a ``FileExplorerStyleDebugOption`` and supplies
///   the list, matching the legacy in-view `FileExplorerStyle.allCases` order.
/// - ``notifyStyleDidChange``: posts the app-owned `fileExplorerStyleDidChange`
///   notification so the live outline view reloads with the new style. The
///   `Notification.Name` lives in the app target, so the app supplies the closure.
///
/// The package view therefore holds no reference to the app-target enum,
/// notification name, or application delegate.
public struct FileExplorerStyleDebugView: View {
    @AppStorage("fileExplorer.style") private var styleRawValue: Int = 0

    private let options: [FileExplorerStyleDebugOption]
    private let notifyStyleDidChange: @MainActor () -> Void

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - options: The ordered file-explorer style rows, snapshotted from the
    ///     app-target `FileExplorerStyle.allCases`.
    ///   - notifyStyleDidChange: Posts the app-owned `fileExplorerStyleDidChange`
    ///     notification so the live outline view reloads with the new style.
    public init(
        options: [FileExplorerStyleDebugOption],
        notifyStyleDidChange: @escaping @MainActor () -> Void
    ) {
        self.options = options
        self.notifyStyleDidChange = notifyStyleDidChange
    }

    private var currentOption: FileExplorerStyleDebugOption? {
        options.first(where: { $0.rawValue == styleRawValue }) ?? options.first
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File Explorer Style")
                .font(.headline)

            ForEach(options) { style in
                HStack(spacing: 8) {
                    Button(action: {
                        styleRawValue = style.rawValue
                        // Post notification so outline view reloads with new style
                        notifyStyleDidChange()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: styleRawValue == style.rawValue ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(styleRawValue == style.rawValue ? .accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.label)
                                    .font(.system(size: 13, weight: .medium))
                                Text(style.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(styleRawValue == style.rawValue
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                if let currentOption {
                    Text("Current: \(currentOption.label)")
                        .font(.system(size: 11, weight: .medium))
                    Text("Row: \(Int(currentOption.rowHeight))pt, Indent: \(Int(currentOption.indentation))pt, Icon: \(Int(currentOption.iconSize))pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

#endif
#endif
