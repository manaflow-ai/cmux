/// Entry points that show Home in a window (Cmd+1, the pinned sidebar row,
/// `home.show`). `showsHome` is the window's own view state; selecting a
/// workspace clears it (`WindowState.select`).
@MainActor
enum HomeNavigation {
    static func show(in state: WindowState, windows: WindowManager) {
        state.showsHome = true
        windows.stateDidChange(state)
    }
}
