import AppKit
import CmuxSimulator

extension SimulatorRemoteSurfaceView {
    func drawChrome(
        _ profile: SimulatorDeviceChromeProfile,
        orientation: SimulatorOrientation
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let portraitWidth = profile.portraitWidth
        let portraitHeight = profile.portraitHeight
        let orientedWidth = orientation == .portrait || orientation == .portraitUpsideDown
            ? portraitWidth : portraitHeight
        let orientedHeight = orientation == .portrait || orientation == .portraitUpsideDown
            ? portraitHeight : portraitWidth
        let scale = min(bounds.width / orientedWidth, bounds.height / orientedHeight)
        let origin = CGPoint(
            x: bounds.midX - (orientedWidth * scale / 2),
            y: bounds.midY - (orientedHeight * scale / 2)
        )

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        switch orientation {
        case .portrait:
            break
        case .portraitUpsideDown:
            context.translateBy(x: portraitWidth, y: portraitHeight)
            context.rotate(by: .pi)
        case .landscapeLeft:
            context.translateBy(x: portraitHeight, y: 0)
            context.rotate(by: .pi / 2)
        case .landscapeRight:
            context.translateBy(x: 0, y: portraitWidth)
            context.rotate(by: -.pi / 2)
        }
        drawPortraitChrome(profile)
        context.restoreGState()
    }

    private func drawPortraitChrome(_ profile: SimulatorDeviceChromeProfile) {
        let body = profile.bodyRect
        drawButtons(profile.buttons.filter { !$0.onTop })
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: body,
            xRadius: profile.cornerRadius,
            yRadius: profile.cornerRadius
        ).fill()

        if let compositeURL = profile.compositeURL,
           let image = chromeImageCache.image(at: compositeURL) {
            image.draw(in: body)
        } else {
            let images = profile.assets.compactMapValues { chromeImageCache.image(at: $0) }
            let layout = SimulatorDeviceChromeAssetLayout(
                body: body,
                imageSizes: images.mapValues(\.size)
            )
            for name in [
                "topLeft", "top", "topRight", "right",
                "bottomRight", "bottom", "bottomLeft", "left",
            ] {
                guard let image = images[name], let rect = layout.rect(for: name) else { continue }
                image.draw(in: rect)
            }
        }
        drawButtons(profile.buttons.filter(\.onTop))
    }

    private func drawButtons(_ buttons: [SimulatorDeviceChromeProfile.Button]) {
        for button in buttons {
            let isPressed = chromeButtonIsPressed(button)
            let isActive = isPressed || chromeButtonIsHovered(button)
            let offset = isActive ? button.rolloverTranslation : SimulatorInputDelta(x: 0, y: 0)
            drawAsset(
                isPressed ? button.imageDownURL ?? button.imageURL : button.imageURL,
                in: CGRect(
                    x: button.rect.x + 4 + offset.x,
                    y: button.rect.y + 4 + offset.y,
                    width: max(button.rect.width - 8, 1),
                    height: max(button.rect.height - 8, 1)
                )
            )
        }
    }

    private func drawAsset(_ url: URL?, in rect: CGRect) {
        guard let image = chromeImageCache.image(at: url),
              rect.width > 0,
              rect.height > 0 else { return }
        image.draw(in: rect)
    }
}
