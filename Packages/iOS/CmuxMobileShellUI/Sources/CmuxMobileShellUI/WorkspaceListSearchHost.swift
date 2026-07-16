import SwiftUI

/// Owns the native search controller above workspace snapshots that are replaced
/// during refresh. Keeping this view's identity stable prevents live list updates
/// from reconfiguring the system search placement while the field is active.
struct WorkspaceListSearchHost<Content: View>: View {
    @State private var searchText = ""
    private let content: (String) -> Content

    init(@ViewBuilder content: @escaping (String) -> Content) {
        self.content = content
    }

    var body: some View {
        content(searchText)
            .searchable(text: $searchText)
    }
}
