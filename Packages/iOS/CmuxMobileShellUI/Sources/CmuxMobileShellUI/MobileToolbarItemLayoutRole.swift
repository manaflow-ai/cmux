enum MobileToolbarItemLayoutRole {
    case compressibleTitle
    case fixedTrailingControls

    var swiftUILayoutPriority: Double {
        switch self {
        case .compressibleTitle:
            return -1
        case .fixedTrailingControls:
            return 1
        }
    }
}
