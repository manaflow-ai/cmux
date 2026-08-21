/// Axis along which the focused pane's branch grows.
public enum PaneAxis: Sendable {
    /// Selects the nearest left-to-right split and grows its width share.
    case width
    /// Selects the nearest top-to-bottom split and grows its height share.
    case height

    var splitOrientation: String {
        switch self {
        case .width:
            return "horizontal"
        case .height:
            return "vertical"
        }
    }
}
