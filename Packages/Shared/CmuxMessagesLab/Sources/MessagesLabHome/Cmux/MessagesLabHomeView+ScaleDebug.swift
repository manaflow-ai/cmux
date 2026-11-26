import AppKit

// cmux: automation evidence for the per-view render scale (MessagesLab 258b385; scripts/cmux-next/home-scale-change.py).
extension MessagesLabHomeView {
    /// The pane's render scale and the scale of what its visible rows show, for `debugGeometry`:
    /// `renderScale` (MessagesWindowView.renderScale), `windowScale` (its window's backing scale), `rowBitmaps` (visible
    /// text rows that show a bitmap), `rowBitmapsOffScale` (those whose image is not drawn at the view's scale: its pixel
    /// width is not the layer's point width times `renderScale`, or the layer's contentsScale differs: an old-scale
    /// bitmap), `cellsOffScale` (visible cells whose own renderScale differs), `composeScale`, `headerScale`, and the
    /// least and largest image pixels per layer point of those bitmaps (`bitmapPxPerPtMin`, `bitmapPxPerPtMax`).
    func debugScaleGeometry() -> [String: Double] {
        guard let demo = controller.demo else { return [:] }
        let s = demo.renderScale
        var bitmaps = 0, offScale = 0, cellsOff = 0, cellsOffInactive = 0, typingOffInactive = 0
        let typingFill = Fixture.typingColors(inactive: demo.inactive).fill.cgColor
        var ratioMin = CGFloat.infinity, ratioMax: CGFloat = 0
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            if cell.renderScale != s { cellsOff += 1 }
            if cell.inactive != demo.inactive { cellsOffInactive += 1 }
            // A typing row's drawn fill (RowCell.typingBody) is its view's state's, exactly.
            if case .typing? = cell.spec?.kind, cell.typingBody.fillColor != typingFill { typingOffInactive += 1 }
            // Text rows only (a media row's placeholder thumbnail is fitted to its bubble, not drawn at the layer's
            // size), and a shown, unstretched bitmap (long text hides it under its tiles).
            guard case let .part(p)? = cell.spec?.kind, case .text = p.part else { continue }
            let layer = cell.bitmap
            guard !layer.isHidden, layer.contentsCenter == CGRect(x: 0, y: 0, width: 1, height: 1),
                  let raw = layer.contents, CFGetTypeID(raw as AnyObject) == CGImage.typeID, layer.bounds.width >= 4 else { continue }
            let image = unsafeDowncast(raw as AnyObject, to: CGImage.self)  // type checked above (ComposeAttachments' pattern)
            bitmaps += 1
            let ratio = CGFloat(image.width) / layer.bounds.width  // image pixels per layer point
            ratioMin = min(ratioMin, ratio); ratioMax = max(ratioMax, ratio)
            // The image is drawn for the layer's size at its scale (ceil to whole pixels); an image from another
            // scale is off by the layer's width times the scale difference (at least 2 px for a 4 pt layer).
            if layer.contentsScale != s || abs(CGFloat(image.width) - layer.bounds.width * s) > s + 0.5 { offScale += 1 }
        }
        return ["renderScale": Double(s), "windowScale": Double(controller.host.window?.backingScaleFactor ?? 0),
                "rowBitmaps": Double(bitmaps), "rowBitmapsOffScale": Double(offScale), "cellsOffScale": Double(cellsOff),
                "composeScale": Double(demo.compose.renderScale), "headerScale": Double(demo.header.layer.contentsScale),
                "bitmapPxPerPtMin": bitmaps > 0 ? Double(ratioMin) : 0, "bitmapPxPerPtMax": Double(ratioMax),
                // The view's own inactive state (MessagesLab 806ef0c), the visible rows drawn with another one, the
                // window's key state, and whether the bitmaps' colour space is the window screen's (b5742f3 check).
                "viewInactive": demo.inactive ? 1 : 0, "cellsOffInactive": Double(cellsOffInactive),
                "typingOffInactive": Double(typingOffInactive), "windowKey": (controller.host.window?.isKeyWindow ?? false) ? 1 : 0,
                "appActive": NSApp.isActive ? 1 : 0, "lightAppearance": Fixture.lightAppearance ? 1 : 0,
                "colorSpaceIsScreen": controller.host.window?.screen?.colorSpace?.cgColorSpace.map { $0 == DisplayScale.colorSpace } == true ? 1 : 0]
    }
}
