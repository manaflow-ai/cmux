import AppKit
import CmuxNextActions
import CmuxNextDesign
import Observation

/// One rail button: the registry action it runs and its icon.
struct WindowRailItem: Equatable {
    let action: ActionID
    let symbol: String
}

/// The window's icon rail (`window.rail`, a prototype comparing placements):
/// new terminal, browser and agent chat tabs, the notifications panel and
/// history at the top, accounts pinned to the bottom. Each button runs its
/// registry action without a target, the same path as the menu bar and the
/// palette, so it acts on this window's focus (a click on a background
/// window first makes it key). Tooltips are the action's title plus its
/// live shortcut.
enum WindowRail {
    static let width: CGFloat = 48
    static let buttonSize: CGFloat = 34
    static let iconSize: CGFloat = 18

    /// Top group, in order.
    static let items: [WindowRailItem] = [
        WindowRailItem(action: "newSurface", symbol: "apple.terminal"),
        WindowRailItem(action: "openBrowser", symbol: "globe"),
        WindowRailItem(action: "palette.newAgentChat", symbol: "bubble.left.and.text.bubble.right"),
        // The notifications panel stands in for the agent inbox until one exists.
        WindowRailItem(action: "showNotifications", symbol: "tray"),
        WindowRailItem(action: "history.show", symbol: "clock.arrow.circlepath"),
    ]
    /// Pinned to the bottom: Settings > Accounts.
    static let account = WindowRailItem(action: "accounts.show", symbol: "person.crop.circle")

    static var allItems: [WindowRailItem] { items + [account] }

    /// The action's title without a menu ellipsis ("Accounts…").
    static func title(for id: ActionID, registry: ActionRegistry) -> String {
        let title = registry.title(for: id) ?? id.rawValue
        return title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// "New Browser Tab (⇧⌘L)", or the title alone while nothing is bound.
    static func toolTip(for id: ActionID, registry: ActionRegistry) -> String {
        let title = title(for: id, registry: registry)
        return registry.shortcutDisplay(for: id).map { WindowStrings.railToolTip(title, shortcut: $0) } ?? title
    }
}

/// The rail's view. It paints nothing of its own: like the sidebar it sits
/// on the window's shared backdrop. Buttons start below the top row (and
/// the traffic lights), so the rail's top-row space moves the window.
final class WindowRailView: NSView {
    private(set) var buttons: [WindowRailButton] = []
    private let registry: ActionRegistry
    private var shortcutObservation: Task<Void, Never>?

    /// Height of the window's top row (the sidebar header): set by the root.
    var topInset: CGFloat = 0 {
        didSet { if oldValue != topInset { needsLayout = true } }
    }

    init(registry: ActionRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for item in WindowRail.allItems {
            let button = WindowRailButton(item: item, label: WindowRail.title(for: item.action, registry: registry))
            button.onPress = { [registry] in _ = registry.perform(item.action, invocation: ActionInvocation()) }
            addSubview(button)
            buttons.append(button)
        }
        refreshToolTips()
        // Shortcut rebinds change tooltips.
        shortcutObservation = Task { [weak self] in
            for await _ in Observations({ WindowRail.allItems.map { registry.shortcutDisplay(for: $0.action) } }) {
                self?.refreshToolTips()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        shortcutObservation?.cancel()
    }

    override var isFlipped: Bool { true }

    func refreshToolTips() {
        for button in buttons { button.toolTip = WindowRail.toolTip(for: button.item.action, registry: registry) }
    }

    /// Where the first button starts: below the top row, and below the
    /// traffic lights when they reach lower (the rail is under them at the
    /// window's leading edge, or after a hidden sidebar).
    var buttonsTop: CGFloat {
        var top = topInset
        if let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            top = max(top, convert(lights, from: nil).maxY + Metrics.space2)
        }
        return top.rounded(.up)
    }

    override func layout() {
        super.layout()
        let size = WindowRail.buttonSize
        let x = ((bounds.width - size) / 2).rounded()
        var y = buttonsTop
        for button in buttons {
            if button.item == WindowRail.account {
                button.frame = NSRect(x: x, y: bounds.height - Metrics.space3 - size, width: size, height: size)
            } else {
                button.frame = NSRect(x: x, y: y, width: size, height: size)
                y += size + Metrics.space1
            }
        }
    }
}
