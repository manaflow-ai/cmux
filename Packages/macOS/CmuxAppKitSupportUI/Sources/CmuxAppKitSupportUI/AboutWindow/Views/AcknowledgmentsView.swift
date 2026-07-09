#if canImport(AppKit)

internal import SwiftUI

/// Renders the bundled `THIRD_PARTY_LICENSES.md` file in a scrollable,
/// selectable monospaced text view.
///
/// The licenses file is read from `Bundle.main` (the running app bundle, which
/// resolves correctly regardless of the module this view lives in). The
/// "not found" fallback string is injected because it is a localized,
/// user-facing string that must resolve against the app bundle's catalog.
struct AcknowledgmentsView: View {
    private let content: String

    /// Creates the view.
    ///
    /// - Parameter notFound: Localized body text shown when the bundled licenses
    ///   file cannot be read.
    init(notFound: String) {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url) {
            content = text
        } else {
            content = notFound
        }
    }

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

#endif
