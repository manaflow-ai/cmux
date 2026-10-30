public import AppKit
public import CmuxNextWakeups

/// Add Device (plans/cmux-next/add-device-DESIGN.md): the one entry for every new device. One
/// model and one floating card, made once and kept. The card picks the way (a computer on your
/// network, a computer that shows a code, a new device) and hands off to the Add Machine or Add
/// Server card, so the enroll and the approval each stay one flow.
@MainActor
public final class AddDeviceCard {
    public let model: AddDeviceModel
    private var panel: AddDeviceCardPanel?
    private let mainWork: MainWorkScheduler

    /// `mainWork` is the app's one main-thread scheduler, for the card's drawing.
    public init(services: AddDeviceServices, mainWork: MainWorkScheduler) {
        model = AddDeviceModel(services: services)
        self.mainWork = mainWork
    }

    /// Opens the card over `window`, on `way` when given, and reads the network again. The task
    /// ends when the opening's read does (a capture awaits it).
    @discardableResult
    public func open(way: AddDeviceWay? = nil, over window: NSWindow?) -> Task<Void, Never> {
        let panel = panel ?? AddDeviceCardPanel(model: model, mainWork: mainWork)
        self.panel = panel
        panel.present(over: window)
        // task-owner: one listing per opening; a newer opening's begin() supersedes it (generation)
        // main-hop-allow: begin is the card model's main-actor async listing (its awaits are the network browse); the card is already on screen
        return Task { await model.begin(way: way) }
    }

    public var isShown: Bool { panel?.isVisible == true }

    public func close() {
        model.closeCard()
        panel?.orderOut(nil)
    }
}
