import AppKit

/// Session-bound resend metadata and localized labels supplied by the page that owns the prompt.
struct AgentPanePromptAgainMenu: Equatable, Sendable {
    struct Model: Equatable, Sendable {
        let id: String
        let name: String

        init?(report: [String: Any]) {
            guard let id = report["id"] as? String, !id.isEmpty,
                  let name = report["name"] as? String, !name.isEmpty else { return nil }
            self.id = id
            self.name = name
        }
    }

    let sessionId: String
    let rowId: String
    let label: String
    let modelsLabel: String
    let moreModelsLabel: String
    let currentModel: String?
    let latestModels: [Model]
    let moreModels: [Model]

    init?(report body: Any?) {
        guard let object = body as? [String: Any],
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let rowId = object["rowId"] as? String, !rowId.isEmpty,
              let label = object["label"] as? String, !label.isEmpty else { return nil }
        self.sessionId = sessionId
        self.rowId = rowId
        self.label = label
        modelsLabel = object["modelsLabel"] as? String ?? ""
        moreModelsLabel = object["moreModelsLabel"] as? String ?? ""
        currentModel = object["currentModel"] as? String
        latestModels = (object["latestModels"] as? [[String: Any]] ?? []).compactMap(Model.init(report:))
        moreModels = (object["moreModels"] as? [[String: Any]] ?? []).compactMap(Model.init(report:))
    }
}

@MainActor
extension AgentPanePromptAgainMenu {
    func items(page: @escaping (String, [String: String]) -> Void) -> [NSMenuItem] {
        let select: (String?) -> Void = { model in
            var params = ["sessionId": sessionId, "rowId": rowId]
            if let model { params["model"] = model }
            page("chat.sendPromptAgain", params)
        }
        let send = AgentPaneMenuAction.item(label, symbol: "arrow.clockwise") { select(nil) }
        guard !modelsLabel.isEmpty, !latestModels.isEmpty || !moreModels.isEmpty else { return [send] }
        let modelRows: ([Model]) -> [NSMenuItem] = { models in
            models.map { model in
                let item = AgentPaneMenuAction.item(model.name, symbol: nil) { select(model.id) }
                item.state = model.id == currentModel ? .on : .off
                return item
            }
        }
        let choices = NSMenu(title: modelsLabel)
        modelRows(latestModels).forEach(choices.addItem)
        if !moreModels.isEmpty {
            if !latestModels.isEmpty { choices.addItem(.separator()) }
            if moreModelsLabel.isEmpty {
                modelRows(moreModels).forEach(choices.addItem)
            } else {
                let more = NSMenuItem(title: moreModelsLabel, action: nil, keyEquivalent: "")
                more.image = AgentPaneContextMenu.icon("ellipsis")
                let submenu = NSMenu(title: moreModelsLabel)
                modelRows(moreModels).forEach(submenu.addItem)
                more.submenu = submenu
                choices.addItem(more)
            }
        }
        let models = NSMenuItem(title: modelsLabel, action: nil, keyEquivalent: "")
        models.image = AgentPaneContextMenu.icon("arrow.clockwise")
        models.submenu = choices
        return [send, models]
    }
}
