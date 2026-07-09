/// Whether a titlebar double-click should run the standard window action or be
/// suppressed (e.g. when a higher-level surface already consumed it).
public enum TitlebarDoubleClickBehavior: Equatable {
    case standardAction
    case suppress
}
