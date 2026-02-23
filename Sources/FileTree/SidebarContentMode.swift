import SwiftUI

enum SidebarContentMode {
    case tabs
    case fileTree
}

@MainActor
final class SidebarContentModeState: ObservableObject {
    @Published var mode: SidebarContentMode = .tabs
}
