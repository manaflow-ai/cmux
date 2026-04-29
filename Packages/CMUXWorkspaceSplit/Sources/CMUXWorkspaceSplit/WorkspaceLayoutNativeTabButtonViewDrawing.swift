import AppKit

extension WorkspaceLayoutNativeTabButtonView {
    func refreshChrome() {
        guard let onSelect,
              let onClose,
              let onZoomToggle,
              let onContextAction,
              let onBeginTabDrag,
              let onCancelTabDrag else { return }
        update(
            tab: tab,
            paneId: paneId,
            isSelected: isSelected,
            isPaneFocused: isPaneFocused,
            showsZoomIndicator: showsZoomIndicator,
            controlShortcutDigit: controlShortcutDigit,
            showsControlShortcutHint: showsControlShortcutHint,
            shortcutModifierSymbol: shortcutModifierSymbol,
            appearance: splitAppearance,
            contextMenuState: contextMenuState,
            onSelect: onSelect,
            onClose: onClose,
            onZoomToggle: onZoomToggle,
            onContextAction: onContextAction,
            onBeginTabDrag: onBeginTabDrag,
            onCancelTabDrag: onCancelTabDrag
        )
    }

    func syncSpinnerAnimation() {
        let shouldAnimate = tab.isLoading && debugFixedSpinnerPhase == nil
        if shouldAnimate {
            guard spinnerTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            spinnerTimer = timer
        } else {
            spinnerTimer?.invalidate()
            spinnerTimer = nil
        }
    }

    func drawTabChromeContent() {
        if !usesSubviewChrome {
            drawIconContent()
            if !usesSubviewTitleLabel {
                drawTitle()
            }
        } else {
            let tint = isSelected
                ? TabBarColors.nsColorActiveText(for: splitAppearance)
                : TabBarColors.nsColorInactiveText(for: splitAppearance)
            if tab.isLoading {
                drawLoadingSpinner(in: spinner.frame, color: tint)
            }
            if !usesSubviewTitleLabel {
                drawTitle()
            }
        }
        if showsZoomIndicator {
            drawAccessoryButton(
                in: zoomButton.frame,
                symbolName: "arrow.up.left.and.arrow.down.right",
                pointSize: TabBarMetrics.closeIconSize,
                isHovered: isZoomHovered,
                isPressed: isZoomPressed
            )
        }
        drawTrailingAccessory()
    }

    func drawIconContent() {
#if DEBUG
        let iconPointSizeDelta = WorkspaceLayoutTabChromeDebugTuning.current.iconPointSizeDelta
#else
        let iconPointSizeDelta = CGFloat(-0.5)
#endif
        let tint = isSelected
            ? TabBarColors.nsColorActiveText(for: splitAppearance)
            : TabBarColors.nsColorInactiveText(for: splitAppearance)

        if tab.isLoading {
            drawLoadingSpinner(in: iconView.frame, color: tint)
            return
        }

        if let imageData = tab.iconImageData,
           let image = iconView.image ?? NSImage(data: imageData) {
            drawRasterIcon(image, in: iconView.frame)
            return
        }

        guard let iconName = tab.icon else { return }
        workspaceSplitDrawSymbol(
            named: iconName,
            pointSize: symbolPointSize(for: iconName) + iconPointSizeDelta,
            weight: .regular,
            color: tint,
            in: iconView.frame
        )
    }

    func drawTitle() {
        guard !titleLabel.frame.isEmpty else { return }
#if DEBUG
        let tuning = WorkspaceLayoutTabChromeDebugTuning.current
#else
        let tuning = (titlePointSizeDelta: CGFloat(0), titleKern: CGFloat(0))
#endif
        let rect = titleLabel.frame
        let font = NSFont.systemFont(ofSize: titleFontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isSelected
                ? TabBarColors.nsColorActiveText(for: splitAppearance)
                : TabBarColors.nsColorInactiveText(for: splitAppearance),
            .paragraphStyle: paragraphStyle
        ]
        if abs(tuning.titleKern) > 0.0001 {
            attributes[.kern] = tuning.titleKern
        }
#if DEBUG
        switch WorkspaceLayoutTabChromeTitleRenderer.current {
        case .stringDraw:
            (tab.title as NSString).draw(
                with: rect,
                options: WorkspaceLayoutTabChromeTitleDrawMode.selected.options,
                attributes: attributes
            )
        case .textKit:
            drawTitleWithTextKit(in: rect, attributes: attributes)
        }
#else
        (tab.title as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
#endif
    }

    func drawTitleWithTextKit(in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        let storage = NSTextStorage(string: tab.title, attributes: attributes)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        let container = NSTextContainer(size: rect.size)
        container.maximumNumberOfLines = 1
        container.lineBreakMode = .byTruncatingTail
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: container)
        let usedRect = layoutManager.usedRect(for: container)
        let drawOrigin = CGPoint(
            x: rect.minX,
            y: rect.minY + floor((rect.height - usedRect.height) / 2)
        )
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: drawOrigin)
    }

    func drawTrailingAccessory() {
        if showsShortcutHint {
            return
        }

        if shouldShowIndicators {
            if !unreadDot.isHidden {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: unreadDot.frame).fill()
            }
            if !dirtyDot.isHidden {
                TabBarColors.nsColorActiveText(for: splitAppearance)
                    .withAlphaComponent(0.72)
                    .setFill()
                NSBezierPath(ovalIn: dirtyDot.frame).fill()
            }
            return
        }

        if tab.isPinned {
            guard !pinView.isHidden else { return }
            workspaceSplitDrawSymbol(
                named: "pin.fill",
                pointSize: TabBarMetrics.closeIconSize,
                weight: .semibold,
                color: TabBarColors.nsColorInactiveText(for: splitAppearance),
                in: pinView.frame
            )
            return
        }

        guard !closeButton.isHidden else { return }
        drawAccessoryButton(
            in: closeButton.frame,
            symbolName: "xmark",
            pointSize: TabBarMetrics.closeIconSize,
            isHovered: isCloseHovered,
            isPressed: isClosePressed
        )
    }

    var shouldShowIndicators: Bool {
        (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge)
    }

    var shortcutHintLabel: String? {
        guard let controlShortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(controlShortcutDigit)"
    }

    var showsShortcutHint: Bool {
        (showsControlShortcutHint || alwaysShowShortcutHints) && shortcutHintLabel != nil
    }

    var alwaysShowShortcutHints: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: WorkspaceLayoutShortcutHintSettings.alwaysShowHintsKey) != nil else {
            return WorkspaceLayoutShortcutHintSettings.defaultAlwaysShowHints
        }
        return defaults.bool(forKey: WorkspaceLayoutShortcutHintSettings.alwaysShowHintsKey)
    }

    var paneShortcutHintXOffset: CGFloat {
        let defaults = UserDefaults.standard
        let value: Double
        if defaults.object(forKey: WorkspaceLayoutShortcutHintSettings.paneHintXKey) != nil {
            value = defaults.double(forKey: WorkspaceLayoutShortcutHintSettings.paneHintXKey)
        } else {
            value = WorkspaceLayoutShortcutHintSettings.defaultPaneHintX
        }
        return CGFloat(WorkspaceLayoutShortcutHintSettings.clamped(value))
    }

    var paneShortcutHintYOffset: CGFloat {
        let defaults = UserDefaults.standard
        let value: Double
        if defaults.object(forKey: WorkspaceLayoutShortcutHintSettings.paneHintYKey) != nil {
            value = defaults.double(forKey: WorkspaceLayoutShortcutHintSettings.paneHintYKey)
        } else {
            value = WorkspaceLayoutShortcutHintSettings.defaultPaneHintY
        }
        return CGFloat(WorkspaceLayoutShortcutHintSettings.clamped(value))
    }

    var trailingAccessorySlotWidth: CGFloat {
        guard let label = shortcutHintLabel else {
            return accessorySlotSize
        }
        let font = shortcutHintFont()
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let positiveDebugInset = max(0, paneShortcutHintXOffset) + 2
        return max(accessorySlotSize, textWidth + 8 + positiveDebugInset)
    }

    func shortcutHintFont() -> NSFont {
        NSFont.systemFont(ofSize: accessoryFontSize, weight: .semibold)
    }

    func drawAccessoryButton(
        in rect: CGRect,
        symbolName: String,
        pointSize: CGFloat,
        isHovered: Bool,
        isPressed: Bool
    ) {
        workspaceSplitDrawAccessoryButton(
            in: rect,
            symbolName: symbolName,
            pointSize: pointSize,
            isHovered: isHovered,
            isPressed: isPressed,
            appearance: splitAppearance
        )
    }

    func drawRasterIcon(_ image: NSImage, in rect: CGRect) {
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    func drawLoadingSpinner(in rect: CGRect, color: NSColor) {
        let size = TabBarMetrics.iconSize * 0.86
        let spinnerRect = CGRect(
            x: rect.midX - (size / 2),
            y: rect.midY - (size / 2),
            width: size,
            height: size
        )
        let lineWidth = max(1.6, size * 0.14)
        let insetRect = spinnerRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let phase = debugFixedSpinnerPhase ?? CGFloat(
            (Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0
        )

        let ringPath = NSBezierPath(ovalIn: insetRect)
        ringPath.lineWidth = lineWidth
        color.withAlphaComponent(0.20).setStroke()
        ringPath.stroke()

        let arcPath = NSBezierPath()
        arcPath.appendArc(
            withCenter: CGPoint(x: insetRect.midX, y: insetRect.midY),
            radius: insetRect.width / 2,
            startAngle: phase,
            endAngle: phase + (360.0 * 0.28),
            clockwise: false
        )
        arcPath.lineWidth = lineWidth
        arcPath.lineCapStyle = .round
        color.setStroke()
        arcPath.stroke()
    }

    func symbolPointSize(for iconName: String) -> CGFloat {
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, TabBarMetrics.iconSize - 2.5)
        }
        return TabBarMetrics.iconSize
    }

    func configureDebugInteractionState(
        isHovered: Bool,
        isCloseHovered: Bool,
        isClosePressed: Bool,
        isZoomHovered: Bool,
        isZoomPressed: Bool
    ) {
        self.isHovered = isHovered
        self.isCloseHovered = isCloseHovered
        self.isClosePressed = isClosePressed
        self.isZoomHovered = isZoomHovered
        self.isZoomPressed = isZoomPressed
        debugFixedSpinnerPhase = tab.isLoading ? 0 : nil
        refreshChrome()
    }

    func closeButtonBackgroundColor() -> NSColor {
        if isClosePressed {
            return workspaceSplitPressedTabBackground(for: splitAppearance)
        }
        if isCloseHovered {
            return workspaceSplitHoveredTabBackground(for: splitAppearance)
        }
        return .clear
    }

    func zoomButtonBackgroundColor() -> NSColor {
        if isZoomPressed {
            return workspaceSplitPressedTabBackground(for: splitAppearance)
        }
        if isZoomHovered {
            return workspaceSplitHoveredTabBackground(for: splitAppearance)
        }
        return .clear
    }
}
