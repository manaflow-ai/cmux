/// The workspace terminal font-size operation accepted by the control socket.
public enum ControlWorkspaceFontSizeAction: String, CaseIterable, Sendable, Equatable {
    case increase
    case decrease
    case reset
}
