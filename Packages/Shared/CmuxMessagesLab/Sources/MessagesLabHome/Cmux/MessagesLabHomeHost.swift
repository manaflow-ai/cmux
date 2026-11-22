// cmux: what the host app gives the Home transcript. Not a vendored file.
import AppKit

/// The host's hooks for the Home transcript, set once before its first frame (``MessagesLabHomeView/host``): its
/// motion gate and its tooltip. Each default is the package's own behaviour, for a host that sets none.
public struct MessagesLabHomeHost {
    /// Whether Home activity loops (the waveform and typing dots) animate. cmux-next sets its motion gate
    /// (`Motion.home`, which obeys Reduce Motion and the animation settings); the default stills them under Reduce
    /// Motion. Still bars show the accent instead.
    public var voiceMotionGate: @MainActor () -> Bool = { !MessagesLabHomeView.reducesMotion }

    /// How a transcript control shows its tooltip (``AppKit/NSView/setHomeToolTip(_:)``); nil text: none. cmux-next
    /// installs its one themed tooltip (`NSView.themedToolTip`, the look of every tooltip in the app; Lawrence
    /// 2026-11-20); the default is AppKit's.
    public var showToolTip: @MainActor (_ view: NSView, _ text: String?) -> Void = { view, text in
        view.toolTip = text // tooltip-native-allow: the package's fallback for a host without its own tooltip
    }

    /// How a control shows tooltips for parts of itself (a segmented control's segments), in its coordinates; each
    /// call replaces the previous ones. cmux-next installs `NSView.setThemedToolTipRegions`; the default is AppKit's.
    public var showToolTipRegions: @MainActor (_ view: NSView, _ regions: [(rect: NSRect, text: String)]) -> Void = { view, regions in
        view.removeAllToolTips()
        for region in regions {
            view.addToolTip(region.rect, owner: region.text as NSString, userData: nil) // tooltip-native-allow: the package's fallback for a host without its own tooltip
        }
    }

    /// The package's own behaviour.
    public init() {}
}
