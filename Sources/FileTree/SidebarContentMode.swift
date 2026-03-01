import SwiftUI

enum SidebarContentMode {
    case tabs
    case fileTree
}

enum SidebarFileTreeLayout: String, CaseIterable, Identifiable {
    case toggle
    case split

    var id: String { rawValue }
}

@MainActor
final class SidebarContentModeState: ObservableObject {
    @Published var mode: SidebarContentMode = .tabs
}
