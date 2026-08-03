import AppKit

@MainActor
final class SimulatorURLMediaClipboardTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let urlField = SimulatorClosureTextField(value: "https://")
    private let clipboardEditor = SimulatorClosureTextView(minimumHeight: 52)
    private var lastClipboardValue = ""

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.urlAndMedia)
        urlField.placeholderString = String(localized: simulatorStrings.url)
        add(urlField)
        let open = SimulatorClosureButton(title: String(localized: simulatorStrings.openURL)) {
            [weak self] in
            guard let self else { return }
            let value = urlField.stringValue
            coordinator.scheduleControlAction("open-url") { await $0.openURL(value) }
        }
        let media = SimulatorClosureButton(title: String(localized: simulatorStrings.addMedia)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("add-media") { await $0.addMedia() }
        }
        add(simulatorRow([open, media]))
        add(simulatorLabel(
            String(localized: simulatorStrings.clipboard),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        ))
        add(clipboardEditor)
        let read = SimulatorClosureButton(title: String(localized: simulatorStrings.readClipboard)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("read-clipboard") { await $0.readClipboard() }
        }
        let write = SimulatorClosureButton(title: String(localized: simulatorStrings.writeClipboard)) {
            [weak self] in
            guard let self else { return }
            let value = clipboardEditor.string
            coordinator.scheduleControlAction("write-clipboard") { await $0.writeClipboard(value) }
        }
        let sync = SimulatorClosureButton(title: String(localized: simulatorStrings.syncClipboard)) {
            [weak coordinator] in
            coordinator?.scheduleControlAction("sync-clipboard") { await $0.syncClipboardFromHost() }
        }
        add(simulatorRow([read, write, sync]))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        guard coordinator.clipboardText != lastClipboardValue else { return }
        lastClipboardValue = coordinator.clipboardText
        clipboardEditor.string = coordinator.clipboardText
    }
}
