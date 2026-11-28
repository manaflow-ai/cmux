import AppKit
import CmuxNextDesign

extension NSView {
    /// The window's traffic lights where they rest on their line (`TrafficLightsLine.restingFrame`: never the buttons'
    /// frames of a moment when AppKit has re-tiled some of them), with the titlebar accessory after them (the incognito badge
    /// while the window's sidebar is closed), in this view's coordinates, when they lie over its
    /// top `band` points: nil when they show elsewhere (the window's sidebar open beside this
    /// view), in full screen, or out of a window. As the tab strip's `windowControlsInset`, so
    /// the Home list and chat avoid exactly what a strip under the top row avoids.
    func homeWindowControls(band: CGFloat) -> CGRect? {
        guard let window, let lights = TrafficLightsLine.restingFrame(in: window) else { return nil }
        let local = convert(Self.homeControls(lights: lights, in: window), from: nil)
        let top = isFlipped ? CGRect(x: 0, y: 0, width: bounds.width, height: band)
            : CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        guard local.intersects(top) else { return nil }
        // Whole points: the layout's frames are on the pixel grid either way.
        return local.integral
    }

    /// The traffic lights' row over this view's top `band` points, for a layout that keeps its
    /// place in the window whether the lights lie over the view or not (the user, 2026-11-19,
    /// msg 42221: Home's search field and list jumped about 28 pt each time the window's sidebar
    /// showed or hid). Its height is the lights' own, in this view's coordinates: the titlebar
    /// accessory after them never moves the line. Its width is the lights' and the accessory's
    /// (`homeWindowControls`) as they lie over a view at the window's left edge, wherever this view
    /// is: so a view that lays out on it lays out the same under the lights (the window's sidebar
    /// hidden, the view at the window's left edge) and clear of them (the sidebar shown beside it).
    /// For what lies over the view now, use `homeWindowControls`. Nil only with no lights near the
    /// view's top: full screen, out of a window, or a view lower in its window.
    func homeLightsRow(band: CGFloat) -> CGRect? {
        guard let window, let lights = TrafficLightsLine.restingFrame(in: window) else { return nil }
        let line = convert(lights, from: nil).integral
        let top = isFlipped ? CGRect(x: 0, y: 0, width: bounds.width, height: band)
            : CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        guard line.maxY > top.minY, line.minY < top.maxY else { return nil }
        let reach = Self.homeControls(lights: lights, in: window).integral
        return CGRect(x: reach.minX, y: line.minY, width: reach.width, height: line.height)
    }

    /// What a control laid out after the window's top-row controls keeps clear of over this view's
    /// top `band` points, in its coordinates, and the line it centres on: the lights with the
    /// accessory at its fully open width after them (``TitlebarAccessoryHosting/titlebarAccessoryReserve``),
    /// so the corner hover's band never moves it out from under the pointer (the person, 2026-11-24:
    /// the Chats button ran from the pointer as the band opened and closed). In full screen, with no
    /// lights, the band alone, on its own line: it opens over the chat's top-left there ("the window
    /// toolbar buttons appear over the chief sidebar button"). Nil when neither lies over the band.
    func homeTopRowReserve(band: CGFloat) -> (clear: CGRect, line: CGRect)? {
        guard let window else { return nil }
        let reserve = (window as? any TitlebarAccessoryHosting)?.titlebarAccessoryReserve.flatMap { $0.width > 0 ? $0 : nil }
        let lights = TrafficLightsLine.restingFrame(in: window)
        var area: CGRect
        let line: CGRect
        if let lights {
            area = lights
            if let reserve, abs(reserve.midY - lights.midY) < lights.height { area = area.union(reserve) }
            line = lights
        } else if let reserve {
            area = reserve
            line = reserve
        } else {
            return nil
        }
        let local = convert(area, from: nil).integral
        let top = isFlipped ? CGRect(x: 0, y: 0, width: bounds.width, height: band)
            : CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        guard local.intersects(top) else { return nil }
        return (local, convert(line, from: nil).integral)
    }

    /// The lights with the titlebar accessory after them on their line, in window coordinates.
    private static func homeControls(lights: CGRect, in window: NSWindow) -> CGRect {
        guard let accessory = (window as? any TitlebarAccessoryHosting)?.titlebarAccessoryFrame, accessory.width > 0,
              abs(accessory.midY - lights.midY) < lights.height else { return lights }
        return lights.union(accessory)
    }
}
