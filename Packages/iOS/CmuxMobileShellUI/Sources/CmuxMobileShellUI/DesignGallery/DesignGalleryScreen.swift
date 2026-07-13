#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Presents the debug-only catalog of static iOS design-system candidates.
///
/// Use this screen from debug navigation or the `CMUX_DESIGN_GALLERY=1`
/// environment entry point. It does not connect to live application data.
public struct DesignGalleryScreen: View {
    @Environment(\.dismiss) private var dismiss

    /// Creates the root design-gallery browser.
    public init() {}

    /// The gallery's navigation hierarchy and dismissal control.
    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DesignGallerySystem.allCases) { system in
                        NavigationLink {
                            DesignGalleryShell(system: system)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(system.number)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(system.displayName)
                                        .font(.headline)
                                    Text(system.tagline)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("DesignGallerySystem-\(system.rawValue)")
                    }
                } footer: {
                    Text(L10n.string(
                        "mobile.designGallery.footer",
                        defaultValue: "Static design-system candidates. No live data."
                    ))
                }
            }
            .navigationTitle(L10n.string("mobile.designGallery.title", defaultValue: "Design Gallery"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
