import AppKit
import CoreText

extension TabCell {
    /// How a title `textWidth` wide draws in a visible area `visibleWidth` wide.
    ///
    /// Middle truncation (#28625) keeps a distinguishing suffix ("Helper 1", "Helper 2") while the
    /// area still holds a few characters on each side of the "…" (`middleMinimum`, measured from the
    /// title). Narrower, CoreText would draw the ellipsis alone (Lawrence msg 19596, 26 tabs: "all
    /// here is … which is not very helpful"): the title then starts at its first character and
    /// fades at the area's end (Chrome's and Helium's crowded tab, no ellipsis): nil, which clips.
    static func titleTruncation(textWidth: CGFloat, visibleWidth: CGFloat, middleMinimum: CGFloat) -> CTLineTruncationType? {
        textWidth <= visibleWidth + 0.5 || visibleWidth >= middleMinimum ? .middle : nil
    }

    /// The narrowest area in which middle truncation keeps two characters each side of the "…".
    func middleTruncationMinimum(_ title: String) -> CGFloat {
        let kept = String(title.prefix(2)) + "…" + String(title.suffix(2))
        return ceil((kept as NSString).size(withAttributes: [.font: titleFont]).width)
    }
}
