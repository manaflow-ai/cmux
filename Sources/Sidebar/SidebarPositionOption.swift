enum SidebarPositionOption: String, CaseIterable, Identifiable {
    case left
    case top
    case right
    case bottom

    var id: String { rawValue }

    var isHorizontal: Bool {
        switch self {
        case .top, .bottom:
            return true
        case .left, .right:
            return false
        }
    }
}
