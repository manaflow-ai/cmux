#if os(iOS) && DEBUG
/// Debug-only workspace-detail chrome experiments exposed through CMUX Labs.
enum WorkspaceDetailLabVariant: String, CaseIterable, Identifiable, Sendable {
    case titleSwitcher = "title-switcher"
    case terminalFocus = "terminal-focus"
    case switcherSheet = "switcher-sheet"
    case inlineTabs = "inline-tabs"
    case titleStepper = "title-stepper"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .titleSwitcher:
            "rectangle.stack"
        case .terminalFocus:
            "terminal"
        case .switcherSheet:
            "rectangle.bottomhalf.inset.filled"
        case .inlineTabs:
            "rectangle.split.3x1"
        case .titleStepper:
            "arrow.left.arrow.right"
        }
    }
}
#endif
