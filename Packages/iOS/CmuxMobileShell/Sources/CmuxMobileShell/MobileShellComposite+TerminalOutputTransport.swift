extension MobileShellComposite {
    enum TerminalOutputTransport: Equatable {
        case hybrid
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .hybrid:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.bytes", "terminal.render_grid", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "mobile.compatible_tags.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
            case .renderGrid:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.render_grid", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "mobile.compatible_tags.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
            case .rawBytes:
                return [
                    "workspace.updated", "mobile.sync.delta",
                    "terminal.bytes", "terminal.set_font",
                    "notification.dismissed", "notification.badge", "notification.feed.changed",
                    "phone_push.status.changed", "caffeine.status.changed",
                    "mobile.compatible_tags.changed",
                    "browser.frame", "browser.state", "browser.closed", "browser.dialog", "browser.dialog.resolved",
                    "simulator.frame", "simulator.state", "simulator.closed",
                ]
            }
        }

        var debugName: String {
            switch self {
            case .hybrid:
                return "hybrid"
            case .renderGrid:
                return "render_grid"
            case .rawBytes:
                return "raw_bytes"
            }
        }

        var usesRenderGrid: Bool {
            switch self {
            case .hybrid, .renderGrid:
                return true
            case .rawBytes:
                return false
            }
        }
    }

}
