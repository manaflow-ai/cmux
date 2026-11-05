import AppKit
import CmuxNextActions
import CmuxNextHomeEngine

/// The Chief's profile panel beside the chat (``HomeChiefProfilePanel``; it replaced the settings
/// popover): the header's avatar and name pill, `home.toggleChiefSettings` and the pet's Chief Pet
/// Settings… open it. Its Details and Settings tabs hold the Chief's settings card; Computer's Expand
/// opens the large computer page (``ChiefComputerPageService``).
extension HomeHostView {
    /// Wires the panel to this conversation's Chief (once, from `init`).
    func wireProfile(conversation: String) {
        let services = control.services
        ChiefComputerPageService.wire(panel.view, services: services, conversation: conversation)
        panel.view.onClose = { [weak self] in self?.closeProfile() }
        panel.view.onExpand = { [weak services] in
            _ = services?.registry.perform(ChiefComputerPageService.toggleActionID,
                                           invocation: ActionInvocation(arguments: ["conversation": .string(conversation), "open": .string("1")], origin: .user))
        }
        let shown = settingsView.onComputerShown
        settingsView.onComputerShown = { [weak self] in
            shown()
            self?.followComputerControl()
        }
    }

    var profileShown: Bool { panel.isShown }

    /// The name pill's click (or `home.toggleChiefSettings`): the Chief's profile opens beside the chat, or
    /// closes again (never with `openOnly`). Only over the Chief. True if shown.
    @discardableResult
    func toggleChiefSettings(openOnly: Bool = false) -> Bool {
        guard profileShown else { return openProfile(nil) }
        if !openOnly { closeProfile() }
        return openOnly
    }

    /// Opens the panel at `tab` (nil: the tab it showed last); false when this Home shows no Chief on screen.
    @discardableResult
    func openProfile(_ tab: HomeChiefProfileTab?) -> Bool {
        guard showsChiefOnScreen else { return false }
        followComputerControl()
        panel.open(tab)
        return true
    }

    func closeProfile() { panel.close(keyboardTo: focusTarget) }

    /// A new read of the Chief (a message, a turn, a move to the Cloud): the open panel follows it.
    func refreshProfile() {
        guard profileShown else { return }
        settingsView.refresh()
        panel.view.refresh()
        followComputerControl()
    }

    /// The control bar's computer: a Cloud Chief's own sandbox, else the Cloud machine a Chief of this Mac uses.
    func followComputerControl() {
        let services = control.services
        let agent = services.home.cloudChiefs.chief(for: control.conversation.rawValue)?.id
        panel.follow(agent: agent, machine: agent == nil ? settingsView.attachedMachine : nil) { [weak services] in
            services?.chiefComputerControlSource(agent: $0, machine: $1)
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The capture scenes `home-chief-profile-*` (CaptureSceneRegistry+ChiefProfile.swift): the panel at `tab`,
    /// with a fixture computer on Computer. False when it cannot show.
    func debugShowProfile(_ tab: HomeChiefProfileTab, fixtureComputer: Bool) -> Bool {
        guard openProfile(tab) else { return false }
        if fixtureComputer { panel.view.debugShowFixtureComputer() }
        return true
    }
    #endif
}
