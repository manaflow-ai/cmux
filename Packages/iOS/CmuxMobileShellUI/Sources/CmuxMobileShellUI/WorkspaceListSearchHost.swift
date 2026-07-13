import SwiftUI

/// Owns the native workspace-search lifecycle above the live list snapshot.
/// Workspace rows can refresh without replacing the search environment node.
@MainActor
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
