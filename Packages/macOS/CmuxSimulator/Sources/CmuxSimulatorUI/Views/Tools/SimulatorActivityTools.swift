import AppKit
import CmuxSimulator

@MainActor
final class SimulatorActivityTools: SimulatorToolSection, SimulatorToolsSection {
    private let coordinator: SimulatorPaneCoordinator
    private let entriesStack = NSStackView()
    private var signature = ""
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(coordinator: SimulatorPaneCoordinator) {
        self.coordinator = coordinator
        super.init(simulatorStrings.activity)
        entriesStack.orientation = .vertical
        entriesStack.alignment = .leading
        entriesStack.spacing = 8
        add(entriesStack)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update() {
        let nextSignature = coordinator.actionLog.map {
            "\($0.id):\($0.succeeded.map(String.init(describing:)) ?? "nil"):\($0.summary)"
        }.joined(separator: "|")
        guard nextSignature != signature else { return }
        signature = nextSignature
        entriesStack.arrangedSubviews.forEach { entriesStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if coordinator.actionLog.isEmpty {
            entriesStack.addArrangedSubview(simulatorLabel(
                String(localized: simulatorStrings.noActivity),
                color: .secondaryLabelColor
            ))
            return
        }
        for entry in coordinator.actionLog {
            let indicator = simulatorLabel(entry.succeeded == false ? "●" : "•")
            indicator.textColor = entry.succeeded == false ? .systemRed : .secondaryLabelColor
            let action = simulatorLabel(String(localized: simulatorStrings.actionLog(entry.action)))
            let time = simulatorLabel(dateFormatter.string(from: entry.timestamp), color: .secondaryLabelColor)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = simulatorRow([indicator, action, spacer, time])
            let summary = simulatorLabel(
                entry.summary,
                font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular),
                color: .secondaryLabelColor
            )
            let entryStack = NSStackView(views: [row, summary])
            entryStack.orientation = .vertical
            entryStack.alignment = .leading
            entryStack.spacing = 3
            entriesStack.addArrangedSubview(entryStack)
            entryStack.widthAnchor.constraint(equalTo: entriesStack.widthAnchor).isActive = true
        }
    }
}
