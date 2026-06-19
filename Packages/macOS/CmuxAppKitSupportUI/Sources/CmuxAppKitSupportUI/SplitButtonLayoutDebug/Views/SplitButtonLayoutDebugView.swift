#if canImport(AppKit)
#if DEBUG

public import SwiftUI

/// Developer panel that picks the split-button backdrop color style used by the
/// workspace tab chrome.
///
/// The view is a thin editor over the `debugFadeColorStyle` user-default: the
/// radio rows write the selected option index and the live rendering path reads
/// the same key, so selecting a row applies immediately. It owns no app state
/// and is gated to `#if DEBUG` like the rest of the debug-window surface.
public struct SplitButtonLayoutDebugView: View {
    @AppStorage("debugFadeColorStyle") private var backdropStyle = 0

    /// Creates the editor.
    public init() {}

    private var options: [(Int, String)] {
        [
            (0, String(localized: "debug.splitButtonLayout.option.precompositedPane", defaultValue: "Pre-composited paneBackground")),
            (1, String(localized: "debug.splitButtonLayout.option.rawPane", defaultValue: "Raw paneBackground (opaque)")),
            (2, String(localized: "debug.splitButtonLayout.option.rawBar", defaultValue: "barBackground (tab chrome)")),
            (3, String(localized: "debug.splitButtonLayout.option.windowBackground", defaultValue: "windowBackgroundColor")),
            (4, String(localized: "debug.splitButtonLayout.option.controlBackground", defaultValue: "controlBackgroundColor")),
            (5, String(localized: "debug.splitButtonLayout.option.precompositedBar", defaultValue: "Pre-composited barBackground")),
            (6, String(localized: "debug.splitButtonLayout.option.translucentChrome", defaultValue: "Translucent chrome")),
            (7, String(localized: "debug.splitButtonLayout.option.hidden", defaultValue: "Hidden")),
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "debug.splitButtonLayout.title", defaultValue: "Button Backdrop Color"))
                .font(.headline)

            ForEach(options, id: \.0) { id, label in
                HStack {
                    Image(systemName: backdropStyle == id ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(backdropStyle == id ? .accentColor : .secondary)
                    Text(label)
                }
                .contentShape(Rectangle())
                .onTapGesture { backdropStyle = id }
            }

            Text(String(localized: "debug.splitButtonLayout.liveNote", defaultValue: "Changes apply live."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

#endif
#endif
