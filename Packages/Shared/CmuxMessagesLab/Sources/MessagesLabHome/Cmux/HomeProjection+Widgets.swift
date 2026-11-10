import CmuxHomeCore
import CmuxHomeRender

/// Chat widgets (HomeWidgetRowProvider): the projection mounts the widgets it shows through the
/// installed host, keeps their snapshots current for the mapping, and redraws a widget's row in
/// place when its app changes its scene (a page turned, new data).
extension HomeProjection {
    /// Before the items are mapped: every widget part they hold has its latest snapshot, and the
    /// host keeps exactly these mounted for this view.
    func syncWidgets(_ items: [TranscriptItem]) {
        guard let widgets = HomeWidgetRowProvider.installed, let host = widgets.host else { return }
        var keys = Set<String>()
        for item in items where !item.isRetracted {
            for (index, part) in item.parts.enumerated() {
                guard case .widget(let widget) = part else { continue }
                let key = HomeWidgetRowProvider.key(item, part: index)
                keys.insert(key)
                widgets.store(host.snapshot(for: key, widget: widget), for: key)
            }
        }
        host.keep(keys, owner: ObjectIdentifier(self))
        if widgetWatch == nil, !keys.isEmpty { watchWidgets(host) }
    }

    /// One watch per view of the host's changes; `stopWidgets` ends it.
    private func watchWidgets(_ host: any HomeWidgetHosting) {
        let changes = host.changes()
        // task-owner: lives until stopWidgets() (the view closed).
        widgetWatch = Task { @MainActor [weak self] in
            for await key in changes {
                self?.refreshWidget(key)
            }
        }
    }

    /// The widget `key` changed: its row draws the new snapshot, in place (the transcript
    /// re-measures it and animates a new height).
    func refreshWidget(_ key: String) {
        guard !stopped, let widgets = HomeWidgetRowProvider.installed, let host = widgets.host,
              let store = controller.store else { return }
        for item in shown where !item.isRetracted {
            for (index, part) in item.parts.enumerated() {
                guard case .widget(let widget) = part, HomeWidgetRowProvider.key(item, part: index) == key else { continue }
                guard widgets.store(host.snapshot(for: key, widget: widget), for: key) else { return }
                let id = HomeMapping.id(item, aliases: aliases)
                guard let message = store.state.message(id) else { return }
                let parts = HomeMapping.projectedParts(item, summary: shownSummary, media: core.media, links: core.links).parts
                for (shownIndex, shownPart) in parts.enumerated() {
                    guard case let .custom(want) = shownPart, want.kind == HomeWidgetRowProvider.kind,
                          HomeWidgetRowProvider.payload(want)?.key == key,
                          case let .custom(have)? = message.parts[checked: shownIndex], have != want else { continue }
                    controller.dispatch(.setCustomPart(id, shownIndex, want))
                }
                return
            }
        }
    }

    /// The view closed: its widgets are released.
    func stopWidgets() {
        widgetWatch?.cancel()
        widgetWatch = nil
        HomeWidgetRowProvider.installed?.host?.keep([], owner: ObjectIdentifier(self))
    }
}
