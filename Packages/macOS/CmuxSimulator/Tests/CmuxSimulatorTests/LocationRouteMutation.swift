enum LocationRouteMutation: CustomStringConvertible {
    case pause
    case stop

    var description: String {
        switch self {
        case .pause: "pause"
        case .stop: "stop"
        }
    }
}
