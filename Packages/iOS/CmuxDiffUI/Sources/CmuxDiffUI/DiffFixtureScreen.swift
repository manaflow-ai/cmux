public import Foundation
public import SwiftUI

/// DEBUG fixture harness covering every rendering state without network or Git access.
public struct DiffFixtureScreen: View {
    @State private var renderMode: DiffRenderMode = .unified
    private let defaults: UserDefaults
    private let highlighter = HighlighterSwiftCodeHighlighter()

    /// Localized label used by the DEBUG settings entry.
    public static var settingsLabel: String {
        DiffLocalized().string("diff.fixture.settingsLabel", defaultValue: "Diff rendering (ndv2)")
    }

    /// Creates the fixture harness with injected viewed-state persistence.
    /// - Parameter defaults: Defaults suite used by the fixture's viewed store.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The full-screen fixture surface and unified/split toggle.
    public var body: some View {
        DiffScreen(
            patchSet: DiffFixtureFactory().patchSet(),
            renderMode: $renderMode,
            viewedStore: DiffViewedStore(defaults: defaults),
            highlighter: highlighter,
            actions: DiffScreenActions(
                loadLargeFile: { _ in },
                retryFile: { _ in },
                expandContext: { _ in }
            )
        )
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(modeLabel, selection: $renderMode) {
                    Text(unifiedLabel).tag(DiffRenderMode.unified)
                    Text(splitLabel).tag(DiffRenderMode.split)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
        }
    }

    private var navigationTitle: String {
        DiffLocalized().string("diff.fixture.title", defaultValue: "Diff rendering")
    }

    private var modeLabel: String {
        DiffLocalized().string("diff.mode.label", defaultValue: "Layout")
    }

    private var unifiedLabel: String {
        DiffLocalized().string("diff.mode.unified", defaultValue: "Unified")
    }

    private var splitLabel: String {
        DiffLocalized().string("diff.mode.split", defaultValue: "Split")
    }
}
