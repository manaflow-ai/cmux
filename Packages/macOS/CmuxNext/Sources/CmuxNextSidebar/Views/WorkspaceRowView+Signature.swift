import AppKit
import CmuxNextDesign

/// The agent's dot glyph (`appearance.agentSignature`): a static mark at the indicator size before the
/// title, after the agent mark when that sits beside the title too; it never replaces the agent mark.
/// Off (or with no glyph read yet), the row has no view for it and lays out as without the setting.
extension WorkspaceRowView {
    /// Shows `signature`, or removes the mark when nil.
    func configureSignature(_ signature: (id: String, glyph: SidebarAgentSignature)?) {
        self.signature = signature
        guard signature != nil else {
            signatureMark?.removeFromSuperview()
            signatureMark = nil
            return
        }
        if signatureMark == nil {
            let mark = DecorativeImageView()
            mark.imageScaling = .scaleNone
            mark.setAccessibilityElement(false) // the row's label names the agent
            addSubview(mark)
            signatureMark = mark
        }
    }

    /// Places the mark at `textX` on the title line and returns where the title starts after it; `textX`
    /// itself when the row draws no glyph. The image is the cached one of the row's backing scale.
    func layoutSignature(textX: CGFloat, cy: CGFloat) -> CGFloat {
        guard let mark = signatureMark, let signature, let images = agentSignatures?.images else { return textX }
        let side = SidebarStyle.indicatorSize
        let image = images.image(id: signature.id, glyph: signature.glyph, side: side,
                                                            scale: window?.backingScaleFactor ?? 2)
        if mark.image !== image { mark.image = image }
        mark.isHidden = image == nil
        guard image != nil else { return textX }
        mark.frame = NSRect(x: textX + Self.labelInset, y: cy - side / 2, width: side, height: side)
        return SidebarStyle.titleXAfterLeadingMark(textX)
    }
}
