import AppKit
import CmuxNextPages

/// The channels Home as an internal page tab, one per window: a pane tab, so it sits next to the
/// native Home (and any other tab) in a split. Opened by "Open Channels" (palette, File menu,
/// `cmux home channels`).
@MainActor
enum HomeChannelsPageTab {
    static func make(_ services: AppServices) -> WebPageTab {
        WebPageTab(.homeChannels, symbol: "number", title: HomeChannelsStrings.title) { [weak services] in
            guard let services, let view = PageFactory(services: services).homeChannelsWebPage() else { return nil }
            view.onOpenExternal = { [weak services] in services?.home.dock.openLink($0, on: services?.daemon.connection) }
            return view
        }
    }

    @discardableResult
    static func open(_ services: AppServices, focus: Bool = true) -> Bool {
        if services.pages.provider(.homeChannels) == nil { services.pages.register(make(services)) }
        return services.pages.show(.homeChannels, in: services.windows.active, focus: focus) != nil
    }
}

nonisolated enum HomeChannelsStrings {
    static var title: String { String(localized: "homeChannels.page.title", defaultValue: "Channels", table: "Handlers", bundle: .module) }
}
