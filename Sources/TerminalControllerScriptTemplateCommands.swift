import Foundation

/// Socket API commands for script and template CRUD operations.
extension TerminalController {

    // MARK: - Script CRUD

    func v2ScriptList(params: [String: Any]) -> V2CallResult {
        let scripts = ScriptRepository.shared.listScripts()
        return .ok(["scripts": scripts])
    }

    func v2ScriptGet(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        guard let content = ScriptRepository.shared.getScript(named: name) else {
            return .err(code: "not_found", message: "Script '\(name)' not found", data: nil)
        }
        return .ok(["name": name, "content": content])
    }

    func v2ScriptSave(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        guard let content = params["content"] as? String else {
            return .err(code: "missing_param", message: "Missing 'content'", data: nil)
        }
        do {
            try ScriptRepository.shared.saveScript(named: name, content: content)
            return .ok(["saved": true])
        } catch {
            return .err(code: "write_error", message: error.localizedDescription, data: nil)
        }
    }

    func v2ScriptDelete(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        do {
            try ScriptRepository.shared.deleteScript(named: name)
            return .ok(["deleted": true])
        } catch {
            return .err(code: "delete_error", message: error.localizedDescription, data: nil)
        }
    }

    // MARK: - Template CRUD

    func v2TemplateList(params: [String: Any]) -> V2CallResult {
        let templates = TemplateRepository.shared.listTemplates()
        return .ok(["templates": templates])
    }

    func v2TemplateGet(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        do {
            let template = try TemplateRepository.shared.getTemplate(named: name)
            let result = serializeTemplateNode(template.root)
            return .ok(["name": name, "root": result])
        } catch {
            return .err(code: "not_found", message: "Template '\(name)' not found", data: nil)
        }
    }

    func v2TemplateSave(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        guard let rootDict = params["root"] as? [String: Any] else {
            return .err(code: "missing_param", message: "Missing 'root' object", data: nil)
        }
        let root = deserializeTemplateNode(rootDict)
        let template = WorkspaceTemplate(root: root)
        do {
            try TemplateRepository.shared.saveTemplate(named: name, template: template)
            return .ok(["saved": true])
        } catch {
            return .err(code: "write_error", message: error.localizedDescription, data: nil)
        }
    }

    func v2TemplateDelete(params: [String: Any]) -> V2CallResult {
        guard let name = params["name"] as? String else {
            return .err(code: "missing_param", message: "Missing 'name'", data: nil)
        }
        do {
            try TemplateRepository.shared.deleteTemplate(named: name)
            return .ok(["deleted": true])
        } catch {
            return .err(code: "delete_error", message: error.localizedDescription, data: nil)
        }
    }

    // MARK: - Template Serialization Helpers

    private func serializeTemplateNode(_ node: TemplateNode) -> [String: Any] {
        var result: [String: Any] = ["title": node.title]
        if let color = node.color { result["color"] = color }
        if let command = node.command { result["command"] = command }
        if !node.children.isEmpty {
            result["children"] = node.children.map { serializeTemplateNode($0) }
        }
        return result
    }

    private func deserializeTemplateNode(_ dict: [String: Any]) -> TemplateNode {
        let title = dict["title"] as? String ?? "Workspace"
        let color = dict["color"] as? String
        let command = dict["command"] as? String
        let childDicts = dict["children"] as? [[String: Any]] ?? []
        let children = childDicts.map { deserializeTemplateNode($0) }
        return TemplateNode(title: title, color: color, command: command, children: children)
    }
}
