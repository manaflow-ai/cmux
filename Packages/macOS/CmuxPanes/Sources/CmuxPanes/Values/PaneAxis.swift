/// Axis along which the focused pane's branch changes size.
public enum PaneAxis: Sendable {
    /// Selects the nearest left-to-right split and adjusts its width share.
    case width
    /// Selects the nearest top-to-bottom split and adjusts its height share.
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
