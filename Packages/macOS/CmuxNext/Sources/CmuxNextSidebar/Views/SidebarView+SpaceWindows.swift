extension SidebarView {
    /// The switcher's window marks (design/spaces.md "The switcher (PR 3)"): the App fills them and runs their actions.
    public var spaceWindowMarks: SpaceWindowMarks { profileBar.windowMarks }

    /// The window closed: the switcher stops observing the windows and redrawing its marks (`SidebarBridge.teardown`).
    public func tearDownSpaceWindowMarks() {
        profileBar.windowMarks.tearDown()
        profileBar.markObservation?.cancel()
        profileBar.markObservation = nil
    }
}
