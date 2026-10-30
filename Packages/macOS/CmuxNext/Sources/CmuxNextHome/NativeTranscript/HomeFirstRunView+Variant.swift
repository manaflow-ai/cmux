#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign

/// DEBUG ONLY, exploration: lays the real first-run parts out as a ``HomeFirstRunVariant``
/// (the Home variations gallery). With no variant the shipping `arrange` and `layout` run.
extension HomeFirstRunView {
    func variantDidChange() {
        let variant = variant
        hero.faceOverride = variant?.face
        hero.leading = variant?.leading ?? false
        hero.title.stringValue = variant?.heroTitle ?? HomeStrings.firstRunHeroTitle
        hero.body.stringValue = variant?.heroBody ?? HomeStrings.firstRunHeroBody
        hero.body.isHidden = hero.body.stringValue.isEmpty
        let titleSize = (variant?.heroTitleSize ?? TypeScale.title) * scale
        hero.title.font = .systemFont(ofSize: titleSize, weight: titleSize >= 22 ? .bold : TypeScale.emphasis)
        if let variant {
            starters.look = variant.starterLook
            starters.setPrompts(variant.starters)
            for (row, key) in [(agent, "agent"), (terminal, "terminal"), (pet, "pet")] {
                row.label.stringValue = variant.actionTitles[key] ?? defaultTitle(key)
            }
            setMemoryOfferSilently(variant.actions.contains("memory") ? (variant.actionTitles["memory"] ?? variant.memoryTitle) : nil)
            setIntro(variant.parts.contains(.intro) ? (variant.intro ?? HomeStrings.firstRunIntro) : nil)
            variantHeading.stringValue = variant.heading ?? ""
        } else {
            starters.look = .wrapped
            setIntro(nil)
        }
        for row in [agent, terminal, memory, pet] { style(row, variant) }
        arrange()
        applyStoredColors()
        needsLayout = true
    }

    private func defaultTitle(_ key: String) -> String {
        switch key {
        case "agent": HomeStrings.firstRunStartAgent
        case "terminal": HomeStrings.firstRunOpenTerminal
        default: HomeStrings.firstRunShowPet
        }
    }

    private func setMemoryOfferSilently(_ title: String?) {
        guard let title else { return }
        memory.label.stringValue = title
        memory.setAccessibilityLabel(title)
    }

    private func style(_ row: HomeFirstRunRow, _ variant: HomeFirstRunVariant?) {
        let tiles = variant?.parts.contains(.tiles) ?? false
        row.tileLayout = tiles
        row.heightOverride = tiles ? variant?.tileHeight : (variant?.rowStyle == .tall ? 44 : nil)
        row.plainSurface = variant?.rowStyle == .plain
        row.cornerOverride = variant?.rowStyle == .pill ? 999 : (tiles ? 14 : nil)
        if !tiles { row.label.alignment = .left; row.shortcutLabel.alignment = .right }
    }

    /// The variant's action rows, in its order.
    var variantActionRows: [HomeFirstRunRow] {
        guard let variant else { return actionRows }
        return variant.actions.compactMap { key in
            switch key {
            case "agent": agent
            case "terminal": terminal
            case "memory": memory
            case "pet": pet
            default: nil
            }
        }
    }

    func arrangeVariant(_ variant: HomeFirstRunVariant) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in variantTiles.arrangedSubviews { variantTiles.removeArrangedSubview(view); view.removeFromSuperview() }
        if variantFrame.superview == nil {
            variantFrame.wantsLayer = true
            variantFrame.layer?.cornerRadius = 18
            variantFrame.layer?.cornerCurve = .continuous
            variantFrame.layer?.borderWidth = 1
            addSubview(variantFrame, positioned: .below, relativeTo: stack)
            variantHeading.isSelectable = false
            variantTiles.orientation = .horizontal
            variantTiles.distribution = .fillEqually
            variantTiles.translatesAutoresizingMaskIntoConstraints = false
        }
        variantFrame.isHidden = !variant.framed
        stack.alignment = variant.leading ? .leading : .centerX
        stack.spacing = variant.spacing * scale
        var groups: [[NSView]] = []
        for part in variant.parts {
            switch part {
            case .heading: groups.append([variantHeading])
            case .intro: groups.append([intro])
            case .hero: groups.append([hero])
            case .starters: groups.append([starters])
            case .actions: groups.append(variantActionRows)
            case .tiles:
                for row in variantActionRows { variantTiles.addArrangedSubview(row) }
                groups.append([variantTiles])
            case .switchCard: groups.append([switchCard])
            }
        }
        for group in groups { for view in group { stack.addArrangedSubview(view); view.isHidden = false } }
        for group in groups.dropLast() {
            if let last = group.last { stack.setCustomSpacing(variant.groupGap * scale, after: last) }
        }
        intro.isHidden = !variant.parts.contains(.intro)
        switchCard.isHidden = switchCard.lineViews.isEmpty || !variant.parts.contains(.switchCard)
        stack.isHidden = false
    }

    func layoutVariant(_ variant: HomeFirstRunVariant) {
        let width = max(0, min(variant.width * scale, bounds.width - 48 * scale))
        for row in variantActionRows { row.width = width }
        if variant.parts.contains(.tiles) {
            let count = CGFloat(max(1, variantActionRows.count)), gap = 10 * scale
            variantTiles.spacing = gap
            for row in variantActionRows { row.width = (width - gap * (count - 1)) / count }
        }
        headerWidth.constant = width
        cardWidth.constant = width
        heroWidth.constant = width
        let introW = min(width, (variant.introWidth ?? variant.width) * scale)
        introWidth.constant = introW
        startersWidth.constant = width
        startersHeight.constant = starters.measure(width: width)
        heroHeight.constant = hero.height(for: width)
        introHeight.constant = intro.height(for: introW)
        cardHeight.constant = switchCard.height(for: width)
        variantHeading.font = .systemFont(ofSize: TypeScale.heading * scale, weight: TypeScale.emphasis)
        variantHeading.alignment = variant.leading ? .left : .center
        variantHeading.frame.size.width = width
        let size = stack.fittingSize
        let x = (bounds.width - width) / 2
        let y: CGFloat = switch variant.vertical {
        case .center: max(0, (bounds.height - size.height) / 2)
        case .top: 28 * scale
        case .bottom: max(0, bounds.height - size.height - 18 * scale)
        }
        stack.frame = CGRect(x: x, y: y, width: width, height: size.height)
        variantFrame.frame = stack.frame.insetBy(dx: -28 * scale, dy: -28 * scale)
    }

    func applyVariantColors() {
        guard let variant, let colors else { return }
        variantHeading.textColor = colors.primary
        for row in [agent, terminal, memory, pet] {
            row.applyColors(text: colors.primary, quiet: colors.tertiary, fill: colors.fill, hover: colors.hover, border: colors.border)
        }
        variantFrame.layer?.backgroundColor = colors.fill.cgColor
        variantFrame.layer?.borderColor = colors.border.cgColor
        if variant.introBlue {
            // The sent-message blue Messages uses, white text: Chief's first line reads as a chat bubble.
            intro.applyColors(text: .white, fill: NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1))
            intro.layer?.cornerRadius = 18
        } else {
            intro.layer?.cornerRadius = HomeFirstRunIntro.cornerRadius
        }
    }
}
#endif

#if DEBUG || CMUX_BENCH_HOOKS
extension HomeNativeTranscriptView {
    /// DEBUG: shows the first-run panel as variation `number` (1...16; anything else: the shipping
    /// panel) and returns its caption (nil for the shipping panel).
    @discardableResult public func debugSetFirstRunVariant(_ number: Int) -> String? {
        firstRun.variant = HomeFirstRunVariant.numbered(number)
        // The gallery shows the panel even where the capture Mac's Chief conversation is not the shown one.
        firstRun.isHidden = false
        firstRun.needsLayout = true
        needsLayout = true
        return firstRun.variant?.caption
    }
}
#endif
