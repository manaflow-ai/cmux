/// Where a mounted scene shows, and which of an app's implementations shows there. One rule per
/// surface, shared by the AppKit hosts and the React pages (`cmux.apps.panels.mount {surface}`):
/// the app pane (``AppManifest/scenePane`` of an active app, as the app's page opens it), a sidebar
/// section (``AppManifest/sceneSection(_:)`` of a visible app, as ``AppSectionProvider`` resolves
/// it), the hover card (only the user's own `local/customize` app, as
/// ``SidebarCustomizationService`` resolves it), a Session Info section of a visible app, and a chat
/// widget (`cmux.chat.widget/1`) of a visible app, which the daemon chose for a tool call or a widget
/// part (`apps.chat_widgets.route`). The raw value is the mount's `surface` in its context.
public nonisolated enum AppMountSurface: String, Sendable, Hashable, CaseIterable {
    case pane
    case sidebarSection
    case hoverCard
    case sessionInfoSection
    case chatWidget

    /// The interface a chat widget implements.
    public static let chatWidgetInterface = "cmux.chat.widget/1"

    /// `record`'s implementation for this surface (`id` names a section; the pane and the hover card
    /// have one each and ignore it), or nil when the app shows nothing here.
    public func implementation(of record: AppRecord, id: String?) -> AppImplementation? {
        switch self {
        case .pane:
            guard record.isActive else { return nil }
            return record.manifest.scenePane
        case .sidebarSection:
            guard record.isVisible, let id else { return nil }
            return record.manifest.sceneSection(id)
        case .hoverCard:
            guard record.id == SidebarCustomizationService.userApp, record.isVisible else { return nil }
            return record.manifest.sceneImplementation(interface: SidebarCustomizationService.hoverCardInterface)
        case .sessionInfoSection:
            guard record.isVisible, let id else { return nil }
            return record.manifest.sessionInfoSections.first { $0.id == id }
        case .chatWidget:
            guard record.isVisible else { return nil }
            return record.manifest.sceneImplementation(interface: Self.chatWidgetInterface)
        }
    }
}

nonisolated extension AppManifest {
    /// The sidebar section `id` drawn from a scene; an app with a single scene section answers it for any id.
    public func sceneSection(_ id: String) -> AppImplementation? {
        let drawn = sections.filter(\.hasScene)
        return drawn.first { $0.id == id } ?? (drawn.count == 1 ? drawn.first : nil)
    }

    /// The first implementation of `interface` drawn from a scene.
    public func sceneImplementation(interface: String) -> AppImplementation? {
        implementations.first { $0.interface == interface && $0.hasScene }
    }
}
