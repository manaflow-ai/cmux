public import AppKit

extension SidebarView {
    /// The switcher's window marks (design/spaces.md "The switcher (PR 3)"): the App fills them and runs their actions.
    public var spaceWindowMarks: SpaceWindowMarks { profileBar.windowMarks }

    /// The screen frame of the space dot named `name` in the spaces strip, when the strip draws it (`debug.mouse`'s
    /// `row`: a tour hovers or clicks a space's dot on any runner's window size).
    public func spaceDotFrameOnScreen(named name: String) -> CGRect? {
        let bar = profileBar, rects = bar.slotRects()
        guard !bar.isHiddenOrHasHiddenAncestor, let window = bar.window, let index = bar.model.profiles.firstIndex(where: { $0.name == name }),
              rects.indices.contains(index), bar.dotIsDrawn(at: index) else { return nil }
        return window.convertToScreen(bar.convert(rects[index], to: nil))
    }

    /// The window closed: the switcher stops observing the windows and redrawing its marks (`SidebarBridge.teardown`).
    public func tearDownSpaceWindowMarks() {
        profileBar.windowMarks.tearDown()
        profileBar.markObservation?.cancel()
        profileBar.markObservation = nil
    }
}
