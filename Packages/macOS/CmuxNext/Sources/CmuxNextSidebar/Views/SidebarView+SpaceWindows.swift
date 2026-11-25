extension SidebarView {
    /// The switcher's window marks (design/spaces.md "The switcher (PR 3)"): the App fills them and runs their actions.
    public var spaceWindowMarks: SpaceWindowMarks { profileBar.windowMarks }

    /// Whether the strip currently draws the dot for a profile in its viewport.
    public func spaceDotIsDrawn(_ profile: ProfileKey) -> Bool {
        guard let index = model.profiles.firstIndex(where: { $0.id == profile }) else { return false }
        return profileBar.dotIsDrawn(at: index)
    }

    /// The window closed: the switcher stops observing the windows and redrawing its marks (`SidebarBridge.teardown`).
    public func tearDownSpaceWindowMarks() {
        profileBar.windowMarks.tearDown()
        profileBar.markObservation?.cancel()
        profileBar.markObservation = nil
    }
}
