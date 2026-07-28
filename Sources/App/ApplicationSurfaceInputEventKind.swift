enum ApplicationSurfaceInputEventKind: String, Sendable {
    case mouseMoved = "mouse_moved"
    case leftMouseDown = "left_mouse_down"
    case leftMouseUp = "left_mouse_up"
    case leftMouseDragged = "left_mouse_dragged"
    case rightMouseDown = "right_mouse_down"
    case rightMouseUp = "right_mouse_up"
    case rightMouseDragged = "right_mouse_dragged"
    case scroll
    case key

    var isCoalescibleMotion: Bool {
        self == .mouseMoved || self == .leftMouseDragged || self == .rightMouseDragged
    }
}
