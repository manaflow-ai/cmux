import CmuxNextActions

extension CloudHandlers {
    /// Move to Cloud and Bring Back Local: the palette, the tab and chat right-click
    /// menus and `cmux cloud move` / `cmux cloud bring-back` each run one binding
    /// (``CloudMove``, ``CloudBringBack``).
    static func bindMove(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let reason: @MainActor () -> String? = { services.machines.isFeatureDisabled(.cloud) ? RefusalStrings.turnedOffByOrganization : nil }
        bind(CloudMove.action, registry, reason: reason) { invocation in
            try CloudMove(services: services).start(invocation, context: context)
        }
        bind(CloudBringBack.action, registry, reason: reason) { invocation in
            try CloudBringBack(services: services).start(invocation, context: context)
        }
    }
}
