import AppKit
import CmuxNextDesign

extension NSView {
    /// The window's traffic lights, with the titlebar accessory after them (the incognito badge
    /// while the window's sidebar is closed), in this view's coordinates, when they lie over its
    /// top `band` points: nil when they show elsewhere (the window's sidebar open beside this
    /// view), in full screen, or out of a window. As the tab strip's `windowControlsInset`, so
    /// the Home list and chat avoid exactly what a strip under the top row avoids.
    func homeWindowControls(band: CGFloat) -> CGRect? {
        guard let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) else { return nil }
        var controls = lights
        if let accessory = (window as? any TitlebarAccessoryHosting)?.titlebarAccessoryFrame, accessory.width > 0,
           abs(accessory.midY - lights.midY) < lights.height {
            controls = controls.union(accessory)
        }
        let local = convert(controls, from: nil)
        let top = isFlipped ? CGRect(x: 0, y: 0, width: bounds.width, height: band)
            : CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        guard local.intersects(top) else { return nil }
        // Whole points: the layout's frames are on the pixel grid either way.
        return local.integral
    }
}
