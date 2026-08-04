#if os(iOS)
@testable import CmuxAgentGUIUI
import CmuxAgentGUIProjection
import Testing
import UIKit

extension TranscriptRenderingRegressionTests {
    @available(iOS 26.0, *)
    @Test func productionOrderHoistsComposerAboveOpaqueTranscriptCanvas() throws {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let terminalSurface = UIView(frame: root.view.bounds)
        terminalSurface.backgroundColor = .black
        terminalSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(terminalSurface)
        let composerHeight: CGFloat = 112
        let composer = UIView(frame: CGRect(
            x: 0,
            y: terminalSurface.bounds.height - composerHeight,
            width: terminalSurface.bounds.width,
            height: composerHeight
        ))
        composer.backgroundColor = .red
        terminalSurface.addSubview(composer)

        let transcript = TranscriptLiveContainerViewController(
            theme: AgentGUITheme(terminalTheme: .monokai),
            terminalThemeGeneration: 0
        )
        root.addChild(transcript)
        transcript.view.frame = root.view.bounds
        root.view.addSubview(transcript.view)
        transcript.didMove(toParent: root)
        transcript.setBottomChromeHeight(composerHeight)
        transcript.setBottomEdgeElementContainers([composer])
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        transcript.view.layoutIfNeeded()
        transcript.transcript.collectionView.layoutIfNeeded()
        CATransaction.flush()

        #expect(root.view.subviews.first === terminalSurface)
        #expect(transcript.view.superview === root.view)
        #expect(composer.superview === transcript.view)
        let composerFrame = composer.convert(composer.bounds, to: root.view)
        let samplePoint = CGPoint(x: composerFrame.midX, y: composerFrame.midY)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: root.view.bounds, format: format).image { context in
            root.view.layer.render(in: context.cgContext)
        }
        let sampled = try #require(Self.rgbaPixel(in: image, at: samplePoint))
        #expect(sampled.red > 0.9)
        #expect(sampled.green < 0.1)
        #expect(sampled.blue < 0.1)
        #expect(sampled.alpha > 0.9)
    }

    @available(iOS 26.0, *)
    @Test func repeatedLiveMountsDoNotAccumulateScrollEdgeInteractions() throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        let composer = UIView(frame: CGRect(x: 0, y: 740, width: 393, height: 112))
        root.view.addSubview(composer)

        for _ in 0..<2 {
            do {
                let container = TranscriptLiveContainerViewController(
                    theme: AgentGUITheme(terminalTheme: .monokai),
                    terminalThemeGeneration: 0
                )
                root.addChild(container)
                container.view.frame = root.view.bounds
                root.view.addSubview(container.view)
                container.didMove(toParent: root)
                container.setBottomChromeHeight(composer.bounds.height)
                container.setBottomEdgeElementContainers([composer])
                root.view.layoutIfNeeded()
                container.view.layoutIfNeeded()

                #expect(Self.scrollEdgeInteractionCount(in: composer) == 1)
                #expect(Self.scrollEdgeInteractionCount(in: navigation.navigationBar) == 1)

                container.willMove(toParent: nil)
                container.view.removeFromSuperview()
                container.removeFromParent()
            }
            #expect(composer.superview === root.view)
            #expect(Self.scrollEdgeInteractionCount(in: composer) == 0)
            #expect(Self.scrollEdgeInteractionCount(in: navigation.navigationBar) == 0)
        }
    }

    @available(iOS 26.0, *)
    private static func scrollEdgeInteractionCount(in view: UIView) -> Int {
        view.interactions.compactMap { $0 as? UIScrollEdgeElementContainerInteraction }.count
    }

    private static func rgbaPixel(
        in image: UIImage,
        at point: CGPoint
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let imageRef = image.cgImage else { return nil }
        let pixelX = min(max(Int((point.x * image.scale).rounded(.down)), 0), imageRef.width - 1)
        let pixelY = min(max(Int((point.y * image.scale).rounded(.down)), 0), imageRef.height - 1)
        guard let pixelRef = imageRef.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(pixelRef, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (
            CGFloat(bytes[0]) / 255,
            CGFloat(bytes[1]) / 255,
            CGFloat(bytes[2]) / 255,
            CGFloat(bytes[3]) / 255
        )
    }
}
#endif
