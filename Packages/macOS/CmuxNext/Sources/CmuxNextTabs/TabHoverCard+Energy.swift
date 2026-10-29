import AppKit
import CmuxNextDesign
import Foundation

/// What a tab's hover card asks about the tab's energy use; the App implements it (feature
/// `highEnergyTabs`). Chrome's tab hover card names a background tab's high resource use the same way, and its
/// performance detection offers to discard such a tab
/// (chrome/browser/ui/performance_controls/performance_intervention_button_controller.cc).
@MainActor
public protocol TabEnergySource: AnyObject {
    /// Whether `tab`, hidden, used high energy lately; never for a tab that shows. Asking is one of the source's natural
    /// wakes: it may start a reading, and `changed` runs once that reading lands.
    func usesHighEnergy(_ tab: TabID, changed: @escaping @MainActor () -> Void) -> Bool
    /// The person pressed Discard in `tab`'s card: the page hibernates and reloads when it shows.
    func discard(_ tab: TabID)
}

extension TabHoverCardController {
    /// Whether `tab`'s card says it uses high energy. A later answer of the source refreshes card `id` if it still shows.
    func usesHighEnergy(_ tab: TabID, card id: HoverTargetID) -> Bool {
        guard let energy, !tab.isGroupChip, strip?.model.tab(tab)?.isDormant != true else { return false }
        return energy.usesHighEnergy(tab) { [weak self] in self?.coordinator.contentChanged(id) }
    }

    /// The card's Discard: the tab hibernates and its card goes, as after any action on the tab.
    func discard(_ tab: TabID) {
        energy?.discard(tab)
        coordinator.dismiss(.action)
    }
}

extension TabHoverCardView {
    /// The energy row's words, in the attention ink with its icon.
    static var energyContent: HoverCardRowContent {
        HoverCardRowContent(text: Strings.usingHighEnergy, ink: .attention, iconTone: .attention)
    }

    /// Whether the card says the tab uses high energy, with Discard running `discard`; the next render shows it.
    func setHighEnergy(_ on: Bool, discard: (() -> Void)?) {
        highEnergy = on
        onDiscard = on ? discard : nil
        if !on { discardButton.isHidden = true }
    }

    /// Discard is a button only while it shows: only then does the card take clicks.
    var offersDiscard: Bool { !discardButton.isHidden }

    func setUpDiscardButton() {
        discardButton.title = Strings.discard
        discardButton.bezelStyle = .rounded
        discardButton.controlSize = .small
        discardButton.font = Typography.caption
        discardButton.toolTip = Strings.discardHelp
        discardButton.setAccessibilityHelp(Strings.discardHelp)
        discardButton.actsOnFirstClick = true
        discardButton.target = self
        discardButton.action = #selector(discardPressed)
        discardButton.isHidden = true
        addSubview(discardButton)
    }

    /// Discard's frame in `row`, the last row frame (y up): on the rows' text edge, its own width, in the row's reading
    /// direction.
    func discardFrame(in row: CGRect) -> CGRect {
        let width = min(discardButton.fittingSize.width, row.width)
        let inset = HoverCardRowView.iconSize + Metrics.space2
        let x = userInterfaceLayoutDirection == .rightToLeft ? row.maxX - inset - width : row.minX + inset
        return CGRect(x: x, y: row.minY, width: width, height: row.height)
    }

    @objc private func discardPressed() { onDiscard?() }
}

extension Strings {
    /// A hidden tab's hover card: its renderer used more than a twentieth of a core lately.
    static var usingHighEnergy: String {
        String(localized: "tabs.hoverCard.highEnergy", defaultValue: "Using high energy", bundle: .module)
    }
    /// The card's button that discards the tab (it reloads when shown).
    static var discard: String { String(localized: "tabs.hoverCard.discard", defaultValue: "Discard", bundle: .module) }
    static var discardHelp: String {
        String(localized: "tabs.hoverCard.discard.help", defaultValue: "Discard this tab to save energy. It reloads when you show it again.",
               bundle: .module)
    }
}
