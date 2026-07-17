enum MobileToastContent: Equatable, Sendable {
    case compact(MobileToastText)
    case detailed(title: MobileToastText, message: MobileToastText?)
    case progress(title: MobileToastText, message: MobileToastText?)

    var isCompact: Bool {
        if case .compact = self { return true }
        return false
    }

    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }

    var announcement: String {
        switch self {
        case .compact(let message):
            return message.resolvedValue
        case .detailed(let title, let message), .progress(let title, let message):
            guard let message else { return title.resolvedValue }
            return "\(title.resolvedValue)\n\(message.resolvedValue)"
        }
    }
}
