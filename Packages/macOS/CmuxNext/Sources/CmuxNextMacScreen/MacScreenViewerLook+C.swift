import AppKit
import CmuxNextDesign
import CmuxNextDevices

/// Look C of the viewer pane (`macScreen.viewerLook` = c): a floating glass pill and full-pane states.
///
/// While live, the picture fills the pane and a small glass pill sits centred at its top: the Mac's name, the latency,
/// View or Control, and Disconnect; everything else is in the pill's More menu. Every other state takes the whole pane,
/// centred and large, in plain words: a big symbol, a headline ("studio-mini is asleep"), one line of why, the connect
/// steps by name (never a bare spinner), a primary and a secondary button, and the details faint. These states are for
/// lasting states only: a brief outage keeps the last frame up, uncovered, and the pill says Reconnecting
/// (``MacScreenViewerStyle/quietOutage``). A last frame shows dimmed behind a lasting state. Chrome stays a sibling of
/// the video view, never inside it. No drag, no collapse timer: the gallery renders it the same every run.
@MainActor
enum MacScreenViewerLookC {
    /// The width of a full-pane state's column.
    static let stateWidth: CGFloat = 440

    /// The pill's glass: the transient neutral glass every floating control uses, with a soft shadow.
    static func pillSurface() -> NSView {
        let surface = Glass.makeOverlayPanel(cornerRadius: Metrics.space6, tone: .neutralGlass(.transient)) // concentric-allow: a capsule; the toolbar's layout sets the radius to half its height
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.castShadow = PopupStyle.elevation2
        return surface
    }
}

/// One full-pane state of look C, built into the card's stack (``MacScreenViewerStyle/CardLayout/fullPane``).
@MainActor
struct MacScreenFullPaneState {
    let card: MacScreenCard
    let shown: MacScreenCardView.Shown
    let model: MacScreenPaneModel
    let actions: MacScreenChromeActions

    /// What a state says, before it is laid out.
    private struct Spec {
        var symbol: String
        var ink: KeyPath<MacScreenColors, NSColor> = \.secondary
        var headline: String
        var why: String?
        /// The connect steps in order, and the one under way (steps before it are done).
        var steps: [String] = []
        var activeStep = 0
        var details: String?
        var secondary: NSView?
        var primary: NSView?
    }

    private var name: String { shown.name }
    private var textWidth: CGFloat { MacScreenViewerLookC.stateWidth - 48 }

    func build(in stack: NSStackView) {
        let spec = makeSpec(card)
        let symbol = symbolView(spec.symbol, ink: spec.ink)
        stack.addArrangedSubview(symbol)
        stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: symbol)

        let headline = MacScreenText(spec.headline, font: MacScreenType.title, wraps: true, alignment: .center, width: textWidth)
        headline.setAccessibilityIdentifier("macScreen.state.headline")
        stack.addArrangedSubview(headline)
        var last: NSView = headline
        if let why = spec.why, !why.isEmpty {
            stack.setCustomSpacing(Metrics.space4, after: headline)
            let line = MacScreenText(why, font: MacScreenType.body, ink: \.secondary, wraps: true, alignment: .center, width: textWidth)
            stack.addArrangedSubview(line)
            last = line
        }
        if !spec.steps.isEmpty {
            stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: last)
            let steps = stepList(spec.steps, active: spec.activeStep)
            stack.addArrangedSubview(steps)
            last = steps
        }
        let buttons = [spec.secondary, spec.primary].compactMap { $0 }
        if !buttons.isEmpty {
            stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: last)
            let row = MacScreenStack.make(.horizontal, spacing: Metrics.space5, alignment: .centerY, buttons)
            stack.addArrangedSubview(row)
            last = row
        }
        if let details = spec.details, !details.isEmpty {
            stack.setCustomSpacing(Metrics.space6 + Metrics.space4, after: last)
            let text = MacScreenText(details, font: MacScreenType.caption, ink: \.tertiary, wraps: true, alignment: .center, width: textWidth)
            text.maximumNumberOfLines = 3
            text.cell?.truncatesLastVisibleLine = true
            text.setAccessibilityIdentifier("macScreen.state.details")
            stack.addArrangedSubview(text)
        }
    }

    // MARK: States

    private func makeSpec(_ card: MacScreenCard) -> Spec {
        switch card {
        case .unsupported:
            return Spec(symbol: "link.badge.plus", ink: \.attention,
                        headline: L.t("macScreen.card.linksGoneTitle", "Pairing Links Are No Longer Supported"),
                        why: L.t("macScreen.card.linksGoneBody", "Screen Sharing now connects the Macs signed in to your cmux account. Open Screen Sharing to see them."),
                        secondary: closeTab(id: "macScreen.card.closeTab"),
                        primary: primary(L.t("macScreen.card.openHome", "Open Screen Sharing")) { $0.openHome() })
        case let .connecting(reconnecting):
            let title = reconnecting ? L.t("macScreen.full.reconnectingTitle", "Reconnecting to %@") : L.t("macScreen.full.connectingTitle", "Connecting to %@")
            return Spec(symbol: symbol, headline: String(format: title, name), steps: sessionSteps,
                        activeStep: shown.linkConnected ? 2 : 1, secondary: cancel { $0.disconnect() })
        case .waitingForPicture:
            return Spec(symbol: symbol, headline: String(format: L.t("macScreen.full.connectingTitle", "Connecting to %@"), name),
                        steps: sessionSteps, activeStep: 2, secondary: cancel { $0.disconnect() })
        case .failed:
            return failed()
        case .ended:
            return Spec(symbol: symbol, headline: String(format: L.t("macScreen.full.endedTitle", "Disconnected from %@"), name),
                        secondary: closeTab(), primary: reconnect())
        case .hubConnect:
            let view = MacScreenButton(L.t("macScreen.hub.view", "View Only"), id: "macScreen.hub.connectView") { [actions] in
                actions.requestScope(.view)
            }
            let full = MacScreenButton(L.t("macScreen.hub.control", "Full Control"), role: .primary, hint: .return,
                                       id: "macScreen.hub.connectFull") { [actions] in actions.requestScope(.full) }
            return Spec(symbol: symbol, headline: String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), name),
                        why: L.t("macScreen.hub.connectBody", "View Only shows the screen. Full Control also sends your clicks and keys."),
                        secondary: view, primary: full)
        case let .hubRequesting(scope):
            return Spec(symbol: symbol, headline: String(format: L.t("macScreen.full.connectingTitle", "Connecting to %@"), name),
                        why: scope.title, steps: hubSteps, activeStep: 0,
                        secondary: cancel(id: "macScreen.hub.cancel") { $0.cancelRequest() })
        case let .hubWaiting(scope):
            return Spec(symbol: symbol, headline: String(format: L.t("macScreen.full.connectingTitle", "Connecting to %@"), name),
                        why: String(format: L.t("macScreen.hub.waitingOwnerBody", "You asked for %@. Its owner needs to allow it."), scope.title),
                        steps: hubSteps, activeStep: 1, secondary: cancel(id: "macScreen.hub.cancel") { $0.cancelRequest() })
        case let .hubDeclined(scope):
            return Spec(symbol: "hand.raised", ink: \.attention, headline: L.t("macScreen.hub.declinedTitle", "Declined"),
                        why: String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), name),
                        secondary: closeTab(),
                        primary: primary(L.t("macScreen.hub.askAgain", "Ask Again"), id: "macScreen.hub.askAgain") { $0.requestScope(scope) })
        case let .hubRefused(refusal, requested):
            return refused(refusal, requested: requested)
        case let .hubRevoked(reason):
            let removed = reason.removesAccess
            return Spec(symbol: removed ? "lock" : symbol, ink: removed ? \.danger : \.secondary,
                        headline: removed ? L.t("macScreen.hub.revokedTitle", "Access Removed")
                            : String(format: L.t("macScreen.full.endedTitle", "Disconnected from %@"), name),
                        why: hostReason ?? reason.text(host: name), secondary: closeTab(),
                        primary: reason.canReconnect ? connectAgain() : nil)
        case .hubAccessLowered:
            return Spec(symbol: "eye", ink: \.attention, headline: L.t("macScreen.hub.loweredTitle", "Access Changed to View Only"),
                        why: String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), name),
                        secondary: closeTab(),
                        primary: primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) })
        case let .hubEnded(reason):
            let removed = reason.removesAccess
            return Spec(symbol: removed ? "lock" : symbol, ink: removed ? \.danger : \.secondary,
                        headline: removed ? L.t("macScreen.hub.revokedTitle", "Access Removed")
                            : String(format: L.t("macScreen.full.endedTitle", "Disconnected from %@"), name),
                        why: hostReason ?? reason.text(host: name), secondary: closeTab(),
                        primary: reason.canReconnect ? reconnect() : nil)
        }
    }

    /// A failed session, said as what happened: asleep, locked, no picture, or an error with its details.
    private func failed() -> Spec {
        let retry = primary(L.t("macScreen.card.retry", "Try Again"), hint: .return, id: "macScreen.card.retry") { $0.connect() }
        let detail = shown.failedDetail
        let cause = model.failureCause
        // The host gives a reason as words only (no code): sleep and lock are read from them.
        if case let .host(reason)? = cause {
            let lowered = reason.lowercased()
            if lowered.contains("sleep") {
                return Spec(symbol: "moon.zzz", headline: String(format: L.t("macScreen.full.asleepTitle", "%@ is asleep"), name),
                            why: L.t("macScreen.full.asleepBody", "Its display is off. Wake it, then try again."),
                            details: detail, secondary: closeTab(), primary: retry)
            }
            if lowered.contains("lock") {
                return Spec(symbol: "lock", headline: String(format: L.t("macScreen.full.lockedTitle", "%@ is locked"), name),
                            why: L.t("macScreen.full.lockedBody", "Someone needs to sign in on it first."),
                            details: detail, secondary: closeTab(), primary: retry)
            }
        }
        if cause == nil, model.session?.timedOutStage == nil, shown.linkConnected {
            return Spec(symbol: "display", headline: String(format: L.t("macScreen.full.noPictureTitle", "%@ shows no picture"), name),
                        why: L.t("macScreen.full.noPictureBody", "The link is up, but no picture arrived. Its display may be off, or it has no desktop session."),
                        secondary: closeTab(), primary: retry)
        }
        // The why is one plain line; a link failure's own words (which can be long) go faint below it.
        var why = detail
        var details: String?
        if case .link? = cause {
            why = model.session?.timedOutStage?.timeoutDetail(name: name)
                ?? String(format: L.t("macScreen.card.failedHub", "Check that %@ is awake and online."), name)
            details = detail == why ? nil : detail
        }
        return Spec(symbol: "exclamationmark.triangle", ink: \.attention,
                    headline: String(format: L.t("macScreen.full.errorTitle", "Couldn’t connect to %@"), name),
                    why: why, details: details, secondary: closeTab(), primary: retry)
    }

    private func refused(_ refusal: MacScreenHubRefusal, requested: SessionScope) -> Spec {
        switch refusal {
        case .permissionNone:
            return Spec(symbol: "nosign", ink: \.danger, headline: L.t("macScreen.hub.noneTitle", "No Access"),
                        why: String(format: L.t("macScreen.hub.noneBodyBlocked", "%1$@ doesn’t allow this Mac. Change it on %2$@ in Settings › Devices."), name, name),
                        primary: closeTab())
        case .scopeExceeds:
            return Spec(symbol: "eye", ink: \.attention, headline: L.t("macScreen.hub.viewOnlyTitle", "View Only Access"),
                        why: String(format: L.t("macScreen.hub.viewOnlyBody", "This Mac may only view %@, not control it."), name),
                        secondary: closeTab(),
                        primary: primary(L.t("macScreen.hub.viewInstead", "View Instead"), id: "macScreen.hub.viewInstead") { $0.requestScope(.view) })
        case .hostOffline, .notShared, .notFound, .notSignedIn, .other:
            var spec = Spec(symbol: refusal == .hostOffline ? "wifi.slash" : "exclamationmark.triangle", ink: \.attention,
                            headline: MacScreenCardView.refusedTitle(refusal, host: name),
                            why: MacScreenCardView.refusedBody(refusal, host: name, platform: model.platform), secondary: closeTab())
            if refusal == .notSignedIn {
                let retry = MacScreenButton(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { [actions] in
                    actions.requestScope(requested)
                }
                let signIn = SignInButton { [actions] in actions.signIn() }
                signIn.setAccessibilityIdentifier("macScreen.card.signIn")
                spec.secondary = MacScreenStack.make(.horizontal, spacing: Metrics.space5, alignment: .centerY, [closeTab(), retry])
                spec.primary = signIn
            } else if refusal.canRetry {
                spec.primary = primary(L.t("macScreen.card.retry", "Try Again"), id: "macScreen.card.retry") { $0.requestScope(requested) }
            }
            return spec
        }
    }

    // MARK: Pieces

    /// The machine's symbol: a laptop or a desktop for a Mac, a display for anything else.
    private var symbol: String { model.platform == .linux ? "display" : "desktopcomputer" }

    /// A hub end's host reason, when the shown card has one.
    private var hostReason: String? { shown.failedDetail.isEmpty ? nil : shown.failedDetail }

    /// A device hub tab's steps before a session: ask, the host allows, the link, the picture.
    private var hubSteps: [String] {
        [String(format: L.t("macScreen.full.stepAsking", "Asking %@"), name),
         String(format: L.t("macScreen.full.stepWaiting", "Waiting for %@ to allow"), name),
         String(format: L.t("macScreen.full.stepReaching", "Reaching %@"), name),
         L.t("macScreen.full.stepPicture", "Starting the picture")]
    }

    /// A session's steps: asked (done by the time it connects), the link, the picture.
    private var sessionSteps: [String] {
        [String(format: L.t("macScreen.full.stepAsking", "Asking %@"), name),
         String(format: L.t("macScreen.full.stepReaching", "Reaching %@"), name),
         L.t("macScreen.full.stepPicture", "Starting the picture")]
    }

    private func symbolView(_ name: String, ink: KeyPath<MacScreenColors, NSColor>) -> NSView {
        let font = Typography.system(size: (Typography.title.pointSize * 2.4).rounded(), weight: TypeScale.regular)
        let glyph = MacScreenGlyph(name, font: font, ink: ink)
        glyph.heightAnchor.constraint(equalToConstant: ceil(font.ascender - font.descender)).isActive = true
        glyph.setAccessibilityIdentifier("macScreen.state.symbol")
        return glyph
    }

    /// The steps as a short column: done ones checked, the one under way spinning, the rest faint.
    private func stepList(_ steps: [String], active: Int) -> NSView {
        let rows: [NSView] = steps.enumerated().map { index, title in
            let marker: NSView
            if index == active {
                let spinner = StatusIndicatorView.spinner()
                spinner.translatesAutoresizingMaskIntoConstraints = false
                let side = MacScreenType.body.pointSize + Metrics.space2
                NSLayoutConstraint.activate([
                    spinner.widthAnchor.constraint(equalToConstant: side),
                    spinner.heightAnchor.constraint(equalToConstant: side),
                ])
                spinner.spin(true)
                marker = spinner
            } else {
                marker = MacScreenGlyph(index < active ? "checkmark" : "circle", font: MacScreenType.body,
                                        ink: index < active ? \.secondary : \.tertiary, width: MacScreenType.body.pointSize + Metrics.space2)
            }
            let text = MacScreenText(title, font: index == active ? MacScreenType.emphasized : MacScreenType.body,
                                     ink: index == active ? \.primary : index < active ? \.secondary : \.tertiary)
            let row = MacScreenStack.make(.horizontal, spacing: Metrics.space4, alignment: .centerY, [marker, text])
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.staticText)
            row.setAccessibilityLabel(title)
            return row
        }
        let column = MacScreenStack.make(.vertical, spacing: Metrics.space4, alignment: .leading, rows)
        column.setAccessibilityIdentifier("macScreen.state.steps")
        return column
    }

    private func reconnect() -> NSView {
        primary(L.t("macScreen.card.reconnect", "Reconnect"), hint: .return, id: "macScreen.card.reconnect") { $0.connect() }
    }

    private func connectAgain() -> NSView {
        primary(L.t("macScreen.hub.connectAgain", "Connect Again"), id: "macScreen.hub.connectAgain") { $0.connect() }
    }

    private func closeTab(id: String? = nil) -> MacScreenButton {
        MacScreenButton(L.t("macScreen.card.closeTab", "Close Tab"), id: id) { [actions] in actions.closeTab() }
    }

    private func cancel(id: String? = nil, _ run: @escaping @MainActor (MacScreenChromeActions) -> Void) -> MacScreenButton {
        MacScreenButton(L.t("macScreen.card.cancel", "Cancel"), id: id) { [actions] in run(actions) }
    }

    private func primary(_ title: String, hint: CmuxDialogKeyHint? = nil, id: String? = nil,
                         _ run: @escaping @MainActor (MacScreenChromeActions) -> Void) -> MacScreenButton {
        MacScreenButton(title, role: .primary, hint: hint, id: id) { [actions] in run(actions) }
    }
}
