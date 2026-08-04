/// Axis used when assigning an exact share to the focused pane's branch.
public enum PaneAxis: Sendable {
    /// Selects the nearest left-to-right split and changes its width share.
    case width
    /// Selects the nearest top-to-bottom split and changes its height share.
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
