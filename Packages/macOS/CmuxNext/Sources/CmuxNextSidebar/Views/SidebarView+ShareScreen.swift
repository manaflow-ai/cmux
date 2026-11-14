import AppKit

/// This Mac's Share button in the footer row of the one-list sidebar (the default, `sidebar.groupByComputer` off),
/// which draws no This Mac header and so none of its header's Share button (Leo, ask-0a91bcfdb0: "for
/// screensharing, jf theres no easy path to use it then theres no point even if its the most performant thing in
/// the world"). One button for the whole Mac, at rest, left of the update button and Search
/// (`SidebarFooterBand.placeShareScreen`); a press sends the header's own intent, `SidebarIntent.shareScreen`
/// for This Mac, which `SidebarIntentActions` routes. With a section per computer the header's button is the entry
/// and this one hides; `sidebar.noFade` hides it with the footer.
extension SidebarViewComponents {
    /// This Mac's machine, when the footer's Share button shows for it: the one-list layout lists This Mac.
    static func footerShareMachine(groupsByComputer: Bool, sections: [SidebarSection]) -> MachineID? {
        guard !groupsByComputer else { return nil }
        return sections.lazy.compactMap(\.machine).first { $0.kind == .local }?.id
    }

    /// The machine the footer's Share button shares now, nil while it hides (`sidebar.noFade` hides the footer).
    var footerShareMachine: MachineID? {
        design.sidebarSections.noFade ? nil
            : Self.footerShareMachine(groupsByComputer: design.sidebarSections.groupsByComputer, sections: model.sections)
    }

    func buildShareScreen() {
        shareScreenButton.isHidden = true
        shareScreenButton.setAccessibilityIdentifier("cmux.sidebar.shareScreen")
        // The machine at press time: the sections may have changed since the last layout.
        shareScreenButton.onPress = { [weak self] in
            guard let self, let machine = self.footerShareMachine else { return }
            self.model.send(.shareScreen(machine))
        }
        addSubview(shareScreenButton)
    }

    /// Shows or hides the Share button for the current layout and sections; a change lays the footer out again.
    func refreshShareScreen() {
        if SidebarHiddenState.apply(footerShareMachine == nil, to: shareScreenButton) { needsLayout = true }
    }
}
