import AppKit
import CmuxFoundation

@MainActor
extension WindowGlassEffect {
    @MainActor
    final class OriginalContentLayoutState: NSObject {
        let translatesAutoresizingMaskIntoConstraints: Bool
        let autoresizingMask: NSView.AutoresizingMask

        init(view: NSView) {
            translatesAutoresizingMaskIntoConstraints = view.translatesAutoresizingMaskIntoConstraints
            autoresizingMask = view.autoresizingMask
        }

        func restore(to view: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
            view.autoresizingMask = autoresizingMask
        }
    }

    final class GlassBackgroundView: NSView {
        private let effectView: NSView
        private let tintOverlay: NSView
        private let usesNativeGlass: Bool
        private var effectTopConstraint: NSLayoutConstraint!
        private weak var observedWindow: NSWindow?
        private var currentTintColor: NSColor?

        init(
            frame: NSRect,
            topOffset: CGFloat,
            tintColor: NSColor?,
            style: WindowGlassEffectStyle?,
            cornerRadius: CGFloat?,
            isKeyWindow: Bool
        ) {
            if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
                effectView = glassClass.init(frame: .zero)
                usesNativeGlass = true
            } else {
                let fallbackView = NSVisualEffectView(frame: .zero)
                fallbackView.blendingMode = .behindWindow
                fallbackView.material = .underWindowBackground
                fallbackView.state = .active
                effectView = fallbackView
                usesNativeGlass = false
            }
            tintOverlay = NSView(frame: .zero)

            super.init(frame: frame)

            identifier = WindowGlassEffect.backgroundIdentifier
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.isOpaque = false

            effectView.translatesAutoresizingMaskIntoConstraints = false
            effectView.wantsLayer = true
            addSubview(effectView)
            effectTopConstraint = effectView.topAnchor.constraint(equalTo: topAnchor, constant: topOffset)
            NSLayoutConstraint.activate([
                effectTopConstraint,
                effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
                effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            tintOverlay.translatesAutoresizingMaskIntoConstraints = false
            tintOverlay.wantsLayer = true
            tintOverlay.alphaValue = 0
            addSubview(tintOverlay, positioned: .above, relativeTo: effectView)
            NSLayoutConstraint.activate([
                tintOverlay.topAnchor.constraint(equalTo: effectView.topAnchor),
                tintOverlay.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                tintOverlay.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                tintOverlay.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            ])

            configure(
                tintColor: tintColor,
                style: style,
                cornerRadius: cornerRadius,
                isKeyWindow: isKeyWindow
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateObservedWindow(window)
        }

        func updateTopOffset(_ offset: CGFloat) {
            effectTopConstraint.constant = offset
        }

        func configure(
            tintColor: NSColor?,
            style: WindowGlassEffectStyle?,
            cornerRadius: CGFloat?,
            isKeyWindow: Bool
        ) {
            currentTintColor = tintColor
            effectView.layer?.cornerRadius = cornerRadius ?? 0
            if usesNativeGlass {
                updateNativeGlassConfiguration(
                    on: effectView,
                    color: tintColor,
                    style: style,
                    cornerRadius: cornerRadius
                )
                updateInactiveTintOverlay(tintColor: tintColor, isKeyWindow: isKeyWindow)
            } else if let tintColor {
                effectView.layer?.masksToBounds = cornerRadius != nil
                let fallbackTint = tintColor.withAlphaComponent(min(tintColor.alphaComponent, 0.45))
                tintOverlay.layer?.backgroundColor = fallbackTint.cgColor
                tintOverlay.alphaValue = 1
            } else {
                effectView.layer?.masksToBounds = cornerRadius != nil
                tintOverlay.layer?.backgroundColor = nil
                tintOverlay.alphaValue = 0
            }
        }

        private func updateObservedWindow(_ window: NSWindow?) {
            guard usesNativeGlass else { return }
            if let observedWindow, observedWindow === window {
                updateInactiveTintOverlay(tintColor: currentTintColor, isKeyWindow: observedWindow.isKeyWindow)
                return
            }

            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
            }
            observedWindow = window
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            updateInactiveTintOverlay(tintColor: currentTintColor, isKeyWindow: window.isKeyWindow)
        }

        @objc private func windowDidBecomeKey(_ notification: Notification) {
            updateInactiveTintOverlay(tintColor: currentTintColor, isKeyWindow: true)
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            updateInactiveTintOverlay(tintColor: currentTintColor, isKeyWindow: false)
        }

        private func updateInactiveTintOverlay(tintColor: NSColor?, isKeyWindow: Bool) {
            guard let tintColor else {
                tintOverlay.layer?.backgroundColor = nil
                tintOverlay.alphaValue = 0
                return
            }

            tintOverlay.layer?.backgroundColor = tintColor.withAdjustedSaturation(by: 1.2).cgColor
            tintOverlay.alphaValue = isKeyWindow ? 0 : (tintColor.isLightColor ? 0.35 : 0.85)
        }

        private func updateNativeGlassConfiguration(
            on glassView: NSView,
            color: NSColor?,
            style: WindowGlassEffectStyle?,
            cornerRadius: CGFloat?
        ) {
            let tintSelector = NSSelectorFromString("setTintColor:")
            if glassView.responds(to: tintSelector) {
                glassView.perform(tintSelector, with: color)
            }

            if let cornerRadius {
                let cornerRadiusSelector = NSSelectorFromString("setCornerRadius:")
                if glassView.responds(to: cornerRadiusSelector) {
                    typealias CornerRadiusSetter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
                    guard let implementation = glassView.method(for: cornerRadiusSelector) else { return }
                    let setter = unsafeBitCast(implementation, to: CornerRadiusSetter.self)
                    setter(glassView, cornerRadiusSelector, cornerRadius)
                }
            }

            if let style {
                let styleSelector = NSSelectorFromString("setStyle:")
                guard glassView.responds(to: styleSelector) else { return }
                typealias StyleSetter = @convention(c) (AnyObject, Selector, Int) -> Void
                guard let implementation = glassView.method(for: styleSelector) else { return }
                let setter = unsafeBitCast(implementation, to: StyleSetter.self)
                setter(glassView, styleSelector, style.rawNSGlassEffectViewStyle)
            }
        }
    }

    final class GlassRootView: NSView {
        let foregroundContainer = NSView(frame: .zero)
        weak var originalContentView: NSView?

        private let backgroundView: GlassBackgroundView

        override var isOpaque: Bool { false }

        init(
            frame: NSRect,
            topOffset: CGFloat,
            tintColor: NSColor?,
            style: WindowGlassEffectStyle?,
            cornerRadius: CGFloat?,
            isKeyWindow: Bool
        ) {
            backgroundView = GlassBackgroundView(
                frame: frame,
                topOffset: topOffset,
                tintColor: tintColor,
                style: style,
                cornerRadius: cornerRadius,
                isKeyWindow: isKeyWindow
            )

            super.init(frame: frame)

            identifier = WindowGlassEffect.rootIdentifier
            autoresizingMask = [.width, .height]
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.isOpaque = false

            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(backgroundView)

            foregroundContainer.identifier = WindowGlassEffect.foregroundContainerViewIdentifier
            foregroundContainer.frame = bounds
            foregroundContainer.translatesAutoresizingMaskIntoConstraints = false
            foregroundContainer.wantsLayer = true
            foregroundContainer.layer?.backgroundColor = NSColor.clear.cgColor
            foregroundContainer.layer?.isOpaque = false
            addSubview(foregroundContainer, positioned: .above, relativeTo: backgroundView)

            NSLayoutConstraint.activate([
                backgroundView.topAnchor.constraint(equalTo: topAnchor),
                backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
                backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
                backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

                foregroundContainer.topAnchor.constraint(equalTo: topAnchor),
                foregroundContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
                foregroundContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
                foregroundContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func attachOriginalContentView(_ contentView: NSView) {
            originalContentView = contentView
            contentView.removeFromSuperview()
            contentView.frame = foregroundContainer.bounds
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.autoresizingMask = [.width, .height]
            foregroundContainer.addSubview(contentView, positioned: .below, relativeTo: nil)
        }

        func configure(
            topOffset: CGFloat,
            tintColor: NSColor?,
            style: WindowGlassEffectStyle?,
            cornerRadius: CGFloat?,
            isKeyWindow: Bool
        ) {
            backgroundView.updateTopOffset(topOffset)
            backgroundView.configure(
                tintColor: tintColor,
                style: style,
                cornerRadius: cornerRadius,
                isKeyWindow: isKeyWindow
            )
        }
    }
}

private extension NSColor {
    func withAdjustedSaturation(by factor: CGFloat) -> NSColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(max(saturation * factor, 0), 1),
            brightness: brightness,
            alpha: alpha
        )
    }
}
