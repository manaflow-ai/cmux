import AppKit
import CmuxNextDesign
import CmuxNextHomeModel
import CmuxNextIcons
import CmuxNextSettings

/// Meet Chief on the empty Chief chat (``ChiefOnboarding``): one raised card, one step at a time. A quiet top line
/// with the step count and Skip; the step's title and one or two sentences; its content; then Back and the one
/// primary button (Continue, Start chatting on the last step).
///
/// The steps go from simple to more: what Chief does (agents, memory, follow-ups), what it may do on this Mac (the
/// three permission modes under their Settings names, picked in place, with the line that Chief always asks before
/// money, deletions and sign-ins, and where to change it later), then how cmux looks (three densities and the text
/// size, applied live, so the card itself shows the change). It draws a value (``HomeChiefOnboardingState``) and
/// reports clicks (`onAction`); it holds no model.
final class HomeChiefOnboardingCard: NSView {
    let surface = NSView()
    let progress = ChromeLabel(labelWithString: "")
    let skip = HomeChiefOnboardingButton(style: .quiet, title: HomeChiefOnboardingStrings.skip)
    let title = ChromeLabel(wrappingLabelWithString: "")
    let body = ChromeLabel(wrappingLabelWithString: "")
    let back = HomeChiefOnboardingButton(style: .quiet, title: HomeChiefOnboardingStrings.back)
    let primary = HomeChiefOnboardingButton(style: .primary, title: HomeChiefOnboardingStrings.next)
    /// The access step's note under the modes: Chief's rule to ask before money, deletions and sign-ins (not a lock).
    let note = ChromeLabel(wrappingLabelWithString: HomeChiefOnboardingStrings.toldToAsk)
    /// Where to change it later, or that an administrator sets it, or that the last pick did not save.
    let status = ChromeLabel(wrappingLabelWithString: "")
    let openSettings = HomeChiefOnboardingButton(style: .quiet, title: HomeChiefOnboardingStrings.openSettings)
    /// The look step: the density picker and the text size stepper, each on a recessed track under its label.
    let densityLabel = ChromeLabel(labelWithString: HomeChiefOnboardingStrings.densityLabel)
    let densityTrack = NSView()
    let densities = ChiefOnboardingDensity.allCases.map { HomeChiefOnboardingButton(style: .segment, title: HomeChiefOnboardingCard.densityName($0)) }
    let textSizeLabel = ChromeLabel(labelWithString: HomeChiefOnboardingStrings.textSizeLabel)
    let sizeTrack = NSView()
    let smaller = HomeChiefOnboardingButton(style: .segment, title: "−")
    let textSize = ChromeLabel(labelWithString: "")
    let larger = HomeChiefOnboardingButton(style: .segment, title: "+")
    /// The look step's views, shown only on it.
    private var lookViews: [NSView] { [densityLabel, densityTrack, textSizeLabel, sizeTrack, smaller, textSize, larger] + densities }
    /// The step's rows: what Chief does or what comes later.
    private(set) var features: [HomeChiefOnboardingFeatureRow] = []
    /// The access step's modes.
    private(set) var choices: [HomeChiefOnboardingChoiceRow] = []
    private(set) var state: HomeChiefOnboardingState?
    /// How Meet Chief is drawn (``Style``), read at each ``apply(_:)``.
    private(set) var style: Style = .card
    /// The chat styles' message bubbles behind the step's words, its rows and its note (Chief's side).
    let bodyBubble = NSView()
    let rowsBubble = NSView()
    let noteBubble = NSView()
    private var bubbles: [NSView] { [bodyBubble, rowsBubble, noteBubble] }
    var onAction: (HomeChiefOnboardingAction) -> Void = { _ in }
    /// The live interface scale (``applyScale(_:)``).
    private(set) var scale: CGFloat = 1
    private var colors: Colors?

    static let maxWidth: CGFloat = 420
    static let padding: CGFloat = 20
    static let gap: CGFloat = 16
    static let rowGap: CGFloat = 12
    static let choiceGap: CGFloat = 6
    /// How far a new step's content rises into place.
    static let rise: CGFloat = 6

    /// Meet Chief's look. `card`: one raised card. `chat`: Chief's messages in bubbles on the chat, the buttons
    /// as your replies at the trailing edge. `chatPlain`: the same messages as plain text with no bubble, as
    /// Chief's replies read in the transcript. Set by `defaults write <bundle> home.chiefOnboarding.style chat`
    /// or `debug.onboarding` (`style`).
    enum Style: String { case card, chat, chatPlain }
    static let styleKey = "home.chiefOnboarding.style"
    static var storedStyle: Style { UserDefaults.standard.string(forKey: styleKey).flatMap(Style.init(rawValue:)) ?? .card }
    var isChat: Bool { style != .card }

    private struct Colors {
        var primary, secondary, tertiary, fill, hover, border, accent, onAccent, lit, danger: NSColor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        addSubview(surface)
        for bubble in [bodyBubble, rowsBubble, noteBubble] {
            bubble.wantsLayer = true
            bubble.layer?.cornerCurve = .continuous
            bubble.isHidden = true
            bubble.setAccessibilityElement(false)
            addSubview(bubble)
        }
        for label in [progress, title, body, note, status] {
            label.isSelectable = false
            label.maximumNumberOfLines = 0
            label.setAccessibilityRole(.staticText)
            addSubview(label)
        }
        progress.maximumNumberOfLines = 1
        for track in [densityTrack, sizeTrack] {
            track.wantsLayer = true
            track.layer?.cornerCurve = .continuous
            track.setAccessibilityElement(false)
            addSubview(track)
        }
        for label in [densityLabel, textSizeLabel, textSize] {
            label.isSelectable = false
            label.setAccessibilityRole(.staticText)
            addSubview(label)
        }
        textSize.alignment = .center
        for (density, button) in zip(ChiefOnboardingDensity.allCases, densities) {
            button.setAccessibilityRole(.radioButton)
            button.onClick = { [weak self] in self?.onAction(.density(density)) }
            addSubview(button)
        }
        smaller.setAccessibilityLabel(HomeChiefOnboardingStrings.smaller)
        larger.setAccessibilityLabel(HomeChiefOnboardingStrings.larger)
        smaller.onClick = { [weak self] in self?.onAction(.textSize(-1)) }
        larger.onClick = { [weak self] in self?.onAction(.textSize(1)) }
        for button in [skip, back, primary, openSettings, smaller, larger] { addSubview(button) }
        skip.onClick = { [weak self] in self?.onAction(.skip) }
        back.onClick = { [weak self] in self?.onAction(.back) }
        primary.onClick = { [weak self] in self?.onAction(.next) }
        openSettings.onClick = { [weak self] in
            guard let step = self?.state?.step else { return }
            self?.onAction(.openSettings(step))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(HomeChiefOnboardingStrings.title(.meet))
        applyFonts()
    }

    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Shows `state`. A new step rebuilds the content and plays its short entrance; the same step only updates
    /// what changed (the picked mode, a failed save).
    func apply(_ state: HomeChiefOnboardingState) {
        guard state != self.state || Self.storedStyle != style else { return }
        let newStyle = Self.storedStyle
        let newStep = state.step != self.state?.step || newStyle != style
        style = newStyle
        self.state = state
        progress.stringValue = HomeChiefOnboardingStrings.progress(state.index + 1, of: state.count)
        title.stringValue = HomeChiefOnboardingStrings.title(state.step)
        body.stringValue = HomeChiefOnboardingStrings.body(state.step)
        primary.title = isChat ? HomeChiefOnboardingStrings.chatReply(state.step)
            : state.isLast ? HomeChiefOnboardingStrings.start : HomeChiefOnboardingStrings.next
        body.stringValue = isChat ? HomeChiefOnboardingStrings.chatBody(state.step) : body.stringValue
        surface.isHidden = false
        progress.isHidden = isChat
        title.isHidden = isChat
        bodyBubble.isHidden = style != .chat
        rowsBubble.isHidden = style != .chat || state.step != .meet
        back.isHidden = !state.canGoBack
        let access = state.step == .access, look = state.step == .look
        note.isHidden = !access
        noteBubble.isHidden = style != .chat || !access
        status.isHidden = !access && !look
        openSettings.isHidden = status.isHidden || (access && state.modeManaged)
        status.stringValue = state.writeFailed ? HomeChiefOnboardingStrings.writeFailed
            : look ? HomeChiefOnboardingStrings.lookLater
            : state.modeManaged ? HomeChiefOnboardingStrings.managed : HomeChiefOnboardingStrings.changeLater
        for view in lookViews { view.isHidden = !look }
        for (density, button) in zip(ChiefOnboardingDensity.allCases, densities) { button.isOn = density == state.density }
        textSize.stringValue = HomeChiefOnboardingStrings.points(Int(state.textSize.rounded()))
        smaller.isEnabled = state.canShrinkText
        larger.isEnabled = state.canGrowText
        if newStep { rebuildContent(for: state) }
        for row in choices {
            row.isOn = row.mode == state.mode
            row.isEnabled = state.canChooseMode
            // An administrator's mode is the only one shown: the others are not choices.
            row.isHidden = state.modeManaged && row.mode != state.mode
        }
        applyStoredColors()
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        if newStep { animateContentIn() }
    }

    /// Forgets what it showed (the card left); the next ``apply(_:)`` builds its step again.
    func clear() {
        state = nil
    }

    private func rebuildContent(for state: HomeChiefOnboardingState) {
        for view in features as [NSView] + choices as [NSView] { view.removeFromSuperview() }
        features = []
        choices = []
        switch state.step {
        case .meet:
            features = [
                HomeChiefOnboardingFeatureRow(icon: .agentChat, title: HomeChiefOnboardingStrings.agentsTitle,
                                              detail: HomeChiefOnboardingStrings.agentsDetail),
                HomeChiefOnboardingFeatureRow(icon: .toolThought, title: HomeChiefOnboardingStrings.memoryTitle,
                                              detail: HomeChiefOnboardingStrings.memoryDetail),
                HomeChiefOnboardingFeatureRow(icon: .notification, title: HomeChiefOnboardingStrings.followUpTitle,
                                              detail: HomeChiefOnboardingStrings.followUpDetail),
            ]
        case .access:
            choices = ChiefPermissionMode.allCases.map { mode in
                let row = HomeChiefOnboardingChoiceRow(mode: mode, title: Self.modeName(mode), detail: HomeChiefOnboardingStrings.modeDetail(mode))
                row.onClick = { [weak self] in self?.onAction(.choose(mode)) }
                return row
            }
        case .look:
            break
        }
        for row in features { row.applyScale(scale); addSubview(row) }
        for row in choices { row.applyScale(scale); addSubview(row) }
        setAccessibilityLabel(HomeChiefOnboardingStrings.title(state.step))
    }

    /// The mode's name as Settings shows it (`chief.permissionMode`'s choices), so the card and Settings agree.
    static func modeName(_ mode: ChiefPermissionMode) -> String {
        settingsChoiceName(["chief", "permissionMode"], mode.rawValue)
    }

    /// The density's name as Settings shows it (`appearance.density`'s choices).
    static func densityName(_ density: ChiefOnboardingDensity) -> String {
        settingsChoiceName(["appearance", "density"], density.rawValue)
    }

    /// The title Settings gives `value` of the choice setting at `path`; the value itself when there is none.
    private static func settingsChoiceName(_ path: [String], _ value: String) -> String {
        guard let descriptor = SettingsSchema.descriptor(for: path), case .choice(let choices) = descriptor.kind,
              let choice = choices.first(where: { $0.value == value }) else { return value }
        return choice.title
    }

    /// The step's content rises and fades in, on the Home motion gate (Reduce Motion: a fade only; animation
    /// off: in place). The card itself and its buttons stay still, so the step changes in place.
    private func animateContentIn() {
        for view in [title, body, note, status, openSettings] + lookViews + features as [NSView] + choices as [NSView] {
            guard !view.isHidden else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            Motion.home.set(layer, "transform.translation.y", to: CGFloat(0), movementFade: .fadeIn, from: Self.rise * scale)
            Motion.home.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
        }
    }

    /// The card's entrance the first time it shows: it rises and fades in (as the Chief's intro bubble does).
    func animateIn() {
        wantsLayer = true
        guard let layer else { return }
        Motion.home.set(layer, "transform.translation.y", to: CGFloat(0), movementFade: .fadeIn, from: 2 * Self.rise * scale)
        Motion.home.set(layer, "opacity", to: Float(1), fade: .fadeIn, from: Float(0))
    }

    func applyScale(_ scale: CGFloat) {
        guard self.scale != scale else { return }
        self.scale = scale
        for button in [skip, back, primary, openSettings, smaller, larger] + densities { button.applyScale(scale) }
        for row in features { row.applyScale(scale) }
        for row in choices { row.applyScale(scale) }
        applyFonts()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyFonts() {
        // Concentric with the buttons it holds, `padding` in from its edge.
        surface.layer?.cornerRadius = Metrics.buttonContainer(padding: Self.padding * scale).outerRadius
        progress.font = .systemFont(ofSize: TypeScale.Base.caption * scale)
        title.font = .systemFont(ofSize: TypeScale.Base.title * scale, weight: TypeScale.emphasis)
        body.font = .systemFont(ofSize: TypeScale.Base.body * scale)
        note.font = .systemFont(ofSize: TypeScale.Base.caption * scale)
        status.font = .systemFont(ofSize: TypeScale.Base.caption * scale)
        for label in [densityLabel, textSizeLabel] {
            label.font = .systemFont(ofSize: TypeScale.Base.detail * scale, weight: TypeScale.emphasis)
        }
        textSize.font = .monospacedDigitSystemFont(ofSize: TypeScale.Base.detail * scale, weight: .regular)
        for track in [densityTrack, sizeTrack] { track.layer?.cornerRadius = Metrics.buttonCornerRadius }
    }

    /// Colours from the theme (caller runs inside `performWithTheme`).
    func applyColors(primary: NSColor, secondary: NSColor, tertiary: NSColor, fill: NSColor, hover: NSColor, border: NSColor,
                     accent: NSColor, onAccent: NSColor, lit: NSColor, danger: NSColor) { // theme-scoped
        colors = Colors(primary: primary, secondary: secondary, tertiary: tertiary, fill: fill, hover: hover, border: border,
                        accent: accent, onAccent: onAccent, lit: lit, danger: danger)
        applyStoredColors()
    }

    private func applyStoredColors() {
        guard let colors else { return }
        // In chat the surface is the chat's own page behind Chief's messages, so the transcript under it stays out.
        surface.layer?.backgroundColor = (isChat ? Palette.pageBackground : colors.fill).cgColor
        surface.layer?.borderColor = (isChat ? NSColor.clear : colors.border).cgColor
        for bubble in bubbles {
            bubble.layer?.backgroundColor = colors.fill.cgColor
            bubble.layer?.cornerRadius = Metrics.surfaceCornerRadius * scale
        }
        // In chat, Chief's words read as its messages: primary text, not the card's secondary.
        if isChat { body.textColor = colors.primary; note.textColor = colors.secondary }
        progress.textColor = colors.tertiary
        title.textColor = colors.primary
        body.textColor = colors.secondary
        note.textColor = colors.secondary
        status.textColor = state?.writeFailed == true ? colors.danger : colors.tertiary
        for button in [skip, back, openSettings, primary] {
            button.applyColors(text: button === openSettings ? colors.lit : colors.secondary, accent: colors.accent,
                               onAccent: colors.onAccent, hover: colors.hover)
        }
        for label in [densityLabel, textSizeLabel] { label.textColor = colors.primary }
        textSize.textColor = colors.primary
        // A recessed track; the picked segment rises to the card's own fill with a hairline.
        let track = colors.fill.blended(withFraction: colors.hover.alphaComponent * 1.5, of: colors.hover.withAlphaComponent(1)) ?? colors.fill
        for view in [densityTrack, sizeTrack] { view.layer?.backgroundColor = track.cgColor }
        for button in densities + [smaller, larger] {
            button.applySegmentColors(on: colors.fill, onText: colors.primary, offText: colors.secondary, border: colors.border,
                                      hover: colors.hover)
        }
        for row in features { row.applyColors(primary: colors.primary, secondary: colors.secondary, glyph: colors.secondary) }
        for row in choices {
            row.applyColors(primary: colors.primary, secondary: colors.secondary, quiet: colors.tertiary, fill: colors.fill,
                            hover: colors.hover, border: colors.border, accent: colors.accent, onAccent: colors.onAccent)
        }
    }

    // MARK: Layout

    /// The frames of everything the card shows, for a card `width` wide, from its top; `height` is the card's.
    private func frames(width: CGFloat) -> (height: CGFloat, place: [(NSView, CGRect)]) {
        if isChat { return chatFrames(width: width) }
        let pad = Self.padding * scale, inner = max(0, width - 2 * pad)
        var place: [(NSView, CGRect)] = []
        var y = pad - 4 * scale
        // The top line: the step count, and Skip at the trailing edge (its hover fill runs into the padding).
        let buttonHeight = HomeChiefOnboardingButton.height * scale
        let skipWidth = skip.fittingWidth
        place.append((skip, CGRect(x: width - pad - skipWidth + 8 * scale, y: y, width: skipWidth, height: buttonHeight)))
        let progressHeight = ceil(progress.intrinsicContentSize.height)
        place.append((progress, CGRect(x: pad, y: y + (buttonHeight - progressHeight) / 2, width: max(0, inner - skipWidth), height: progressHeight)))
        y += buttonHeight + 4 * scale
        let titleHeight = ceil(title.size(forWidth: inner).height)
        place.append((title, CGRect(x: pad, y: y, width: inner, height: titleHeight)))
        y += titleHeight + 4 * scale
        let bodyHeight = ceil(body.size(forWidth: inner).height)
        place.append((body, CGRect(x: pad, y: y, width: inner, height: bodyHeight)))
        y += bodyHeight + Self.gap * scale
        for (index, row) in features.enumerated() {
            if index > 0 { y += Self.rowGap * scale }
            let height = row.height(for: inner)
            place.append((row, CGRect(x: pad, y: y, width: inner, height: height)))
            y += height
        }
        let shownChoices = choices.filter { !$0.isHidden }
        for (index, row) in shownChoices.enumerated() {
            if index > 0 { y += Self.choiceGap * scale }
            let height = row.height(for: inner)
            place.append((row, CGRect(x: pad, y: y, width: inner, height: height)))
            y += height
        }
        if !densityTrack.isHidden {
            y = placeLook(&place, y: y, x: pad, width: inner)
        }
        if !note.isHidden {
            y += Self.rowGap * scale
            let height = ceil(note.size(forWidth: inner).height)
            place.append((note, CGRect(x: pad, y: y, width: inner, height: height)))
            y += height
        }
        if !status.isHidden {
            y += (note.isHidden ? Self.rowGap : 6) * scale
            let settingsWidth = openSettings.isHidden ? 0 : openSettings.fittingWidth
            let statusWidth = max(0, inner - (settingsWidth > 0 ? settingsWidth + 4 * scale : 0))
            let statusHeight = ceil(status.size(forWidth: statusWidth).height)
            let line = max(statusHeight, openSettings.isHidden ? 0 : buttonHeight)
            place.append((status, CGRect(x: pad, y: y + (line - statusHeight) / 2, width: statusWidth, height: statusHeight)))
            if !openSettings.isHidden {
                place.append((openSettings, CGRect(x: width - pad - settingsWidth + 8 * scale, y: y + (line - buttonHeight) / 2,
                                                   width: settingsWidth, height: buttonHeight)))
            }
            y += line
        }
        y += Self.gap * scale
        // The footer: Back at the leading edge, the primary at the trailing edge.
        let primaryWidth = max(96 * scale, primary.fittingWidth)
        place.append((primary, CGRect(x: width - pad - primaryWidth, y: y, width: primaryWidth, height: buttonHeight)))
        if !back.isHidden {
            place.append((back, CGRect(x: pad - 8 * scale, y: y, width: back.fittingWidth, height: buttonHeight)))
        }
        y += buttonHeight + pad
        return (ceil(y), place)
    }

    /// The look step's two groups from `y`: each a label over its track; returns the y under them.
    private func placeLook(_ place: inout [(NSView, CGRect)], y start: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        var y = start
        let inset = 2 * scale, segment = (HomeChiefOnboardingButton.height - 2) * scale
        let trackHeight = segment + 2 * inset
        let labelHeight = ceil(densityLabel.intrinsicContentSize.height)
        place.append((densityLabel, CGRect(x: x, y: y, width: width, height: labelHeight)))
        y += labelHeight + 6 * scale
        place.append((densityTrack, CGRect(x: x, y: y, width: width, height: trackHeight)))
        let each = (width - 2 * inset) / CGFloat(densities.count)
        for (index, button) in densities.enumerated() {
            place.append((button, CGRect(x: (x + inset + CGFloat(index) * each).rounded(), y: y + inset, width: each.rounded(), height: segment)))
        }
        y += trackHeight + Self.gap * scale
        place.append((textSizeLabel, CGRect(x: x, y: y, width: width, height: labelHeight)))
        y += labelHeight + 6 * scale
        // The stepper: minus, the size, plus, on one track.
        let stepWidth = 36 * scale, valueWidth = 64 * scale
        let stepperWidth = 2 * stepWidth + valueWidth + 2 * inset
        place.append((sizeTrack, CGRect(x: x, y: y, width: stepperWidth, height: trackHeight)))
        place.append((smaller, CGRect(x: x + inset, y: y + inset, width: stepWidth, height: segment)))
        let valueHeight = ceil(textSize.intrinsicContentSize.height)
        place.append((textSize, CGRect(x: x + inset + stepWidth, y: y + (trackHeight - valueHeight) / 2, width: valueWidth, height: valueHeight)))
        place.append((larger, CGRect(x: x + inset + stepWidth + valueWidth, y: y + inset, width: stepWidth, height: segment)))
        return y + trackHeight
    }

    /// The chat styles: Chief's messages from the leading edge (in bubbles for `chat`), the step's controls under
    /// them, then your replies at the trailing edge (the primary, and Skip or Back beside it), as a chat reads.
    private func chatFrames(width: CGFloat) -> (height: CGFloat, place: [(NSView, CGRect)]) {
        var place: [(NSView, CGRect)] = []
        let bubbled = style == .chat
        let pad = (bubbled ? 12 : 0) * scale, column = (width * 0.86).rounded()
        let inner = max(0, column - 2 * pad), between = (bubbled ? 6 : 12) * scale
        var y: CGFloat = 0
        /// One message: `views` stacked in a bubble (when bubbled) as wide as its widest line.
        func message(_ bubble: NSView, _ rows: [(NSView, (CGFloat) -> CGFloat, CGFloat?)]) {
            let fit = rows.map { $0.2 ?? inner }.max() ?? inner
            var top = y + pad
            for (index, row) in rows.enumerated() {
                if index > 0 { top += Self.rowGap * scale }
                let height = row.1(fit)
                place.append((row.0, CGRect(x: pad, y: top, width: fit, height: height)))
                top += height
            }
            place.append((bubble, CGRect(x: 0, y: y, width: fit + 2 * pad, height: top + pad - y)))
            y = top + pad + between
        }
        let label = { (l: ChromeLabel) -> (NSView, (CGFloat) -> CGFloat, CGFloat?) in
            (l, { ceil(l.size(forWidth: $0).height) }, min(inner, ceil(l.size(forWidth: inner).width) + 1))
        }
        message(bodyBubble, [label(body)])
        if !features.isEmpty { message(rowsBubble, features.map { row -> (NSView, (CGFloat) -> CGFloat, CGFloat?) in (row, { row.height(for: $0) }, nil) }) }
        let shownChoices = choices.filter { !$0.isHidden }
        for (index, row) in shownChoices.enumerated() {
            if index > 0 { y += Self.choiceGap * scale }
            let height = row.height(for: column)
            place.append((row, CGRect(x: 0, y: y, width: column, height: height)))
            y += height
        }
        if !shownChoices.isEmpty { y += between }
        if !densityTrack.isHidden { y = placeLook(&place, y: y, x: 0, width: column) + between }
        if !note.isHidden { message(noteBubble, [label(note)]) }
        if !status.isHidden {
            let settingsWidth = openSettings.isHidden ? 0 : openSettings.fittingWidth
            let statusHeight = ceil(status.size(forWidth: column - settingsWidth).height)
            let buttonHeight = HomeChiefOnboardingButton.height * scale
            let line = max(statusHeight, openSettings.isHidden ? 0 : buttonHeight)
            place.append((status, CGRect(x: 0, y: y + (line - statusHeight) / 2, width: max(0, column - settingsWidth), height: statusHeight)))
            if !openSettings.isHidden {
                // Open Settings follows the line's words, as a link in a message does.
                let after = min(ceil(status.size(forWidth: column).width), max(0, column - settingsWidth)) - 4 * scale
                place.append((openSettings, CGRect(x: after, y: y + (line - buttonHeight) / 2, width: settingsWidth, height: buttonHeight)))
            }
            y += line
        }
        y += 14 * scale
        // Your replies, at the trailing edge: the primary pill, and Back (or Skip) before it.
        let buttonHeight = HomeChiefOnboardingButton.height * scale
        let primaryWidth = primary.fittingWidth
        place.append((primary, CGRect(x: width - primaryWidth, y: y, width: primaryWidth, height: buttonHeight)))
        let quiet = back.isHidden ? skip : back
        let quietWidth = quiet.fittingWidth
        place.append((quiet, CGRect(x: width - primaryWidth - 6 * scale - quietWidth, y: y, width: quietWidth, height: buttonHeight)))
        if !back.isHidden { place.append((skip, CGRect(x: width - primaryWidth - 12 * scale - quietWidth - skip.fittingWidth, y: y,
                                                       width: skip.fittingWidth, height: buttonHeight))) }
        y += buttonHeight
        return (ceil(y), place)
    }

    /// The card's height when `width` wide.
    func height(for width: CGFloat) -> CGFloat { frames(width: width).height }

    override func layout() {
        super.layout()
        surface.frame = bounds
        // Chat styles fill the panel and sit their messages at its bottom, over the message box, as new messages do.
        let laid = frames(width: bounds.width)
        let drop = isChat ? max(0, bounds.height - laid.height) : 0
        for (view, frame) in laid.place where view.frame != frame.offsetBy(dx: 0, dy: drop) { view.frame = frame.offsetBy(dx: 0, dy: drop) }
    }
}
