import CmuxNextDaemon
import Foundation

/// Browser basics on the App's engine (WebKit or CEF): open, navigate,
/// history, URL/title, eval, snapshot, and selector/ref actions. Tabs are
/// cmux-tui frontend browser tabs (`frontend-browser-tabs-v1`); pages live
/// in the App, so every page operation is an App intent.
enum CompatBrowserMethods {
    static let table: [String: CompatHandler] = [
        "browser.open_split": openSplit,
        "browser.navigate": { call in try await page(call) { .navigate(try call.require("url")) } },
        "browser.back": { call in try await page(call) { .back } },
        "browser.forward": { call in try await page(call) { .forward } },
        "browser.reload": { call in try await page(call) { .reload } },
        "browser.url.get": { call in try await stateField(call, "url") },
        "browser.get.url": { call in try await stateField(call, "url") },
        "browser.get.title": { call in try await stateField(call, "title") },
        "browser.eval": eval,
        "browser.snapshot": snapshot,
        "browser.click": { call in try await action(call, CompatBrowserScripts.click) },
        "browser.fill": { call in try await action(call, CompatBrowserScripts.fill) },
        "browser.type": { call in try await action(call, CompatBrowserScripts.type) },
        "browser.focus": { call in try await action(call, CompatBrowserScripts.focus) },
        "browser.get.text": { call in try await action(call, CompatBrowserScripts.text) },
        "browser.get.value": { call in try await action(call, CompatBrowserScripts.value) },
    ]

    static func browserSurface(_ call: CompatCall) async throws -> (CompatWorld, CompatWorld.Surface, CompatTarget) {
        let world = try await call.world()
        let target = call.target(world)
        let explicit = call.string("surface_id") ?? call.string("tab_id") ?? call.string("panel_id")
        let surface = try target.surface()
        guard surface.tab.kind == .browser else {
            throw explicit == nil
                ? ControlError(code: "not_found", message: "No focused browser surface")
                : CompatErrors.invalid("Surface is not a browser")
        }
        guard surface.tab.isFrontendOwned else {
            throw CompatErrors.unsupported("daemon-rendered (CDP) browser tabs are driven by cmux-tui browser commands", method: call.method)
        }
        return (world, surface, target)
    }

    static func run(_ call: CompatCall, _ surface: CompatWorld.Surface, _ operation: CompatBrowserOperation) async throws -> JSON {
        try await call.service.perform(.browser(tabID: surface.modelID, url: surface.tab.url, operation: operation),
                                       within: CompatDeadline.browser)
    }

    static func base(_ world: CompatWorld, _ surface: CompatWorld.Surface, _ target: CompatTarget) -> [String: JSON] {
        CompatJSON.ids(window: (try? target.window()) ?? nil, workspace: world.workspace(surface.workspaceUUID), surface: surface)
    }

    static func page(_ call: CompatCall, _ operation: () throws -> CompatBrowserOperation) async throws -> JSON {
        let op = try operation()
        let (world, surface, target) = try await browserSurface(call)
        _ = try await run(call, surface, op)
        return .object(base(world, surface, target))
    }

    static func stateField(_ call: CompatCall, _ field: String) async throws -> JSON {
        let (world, surface, target) = try await browserSurface(call)
        let state = try await run(call, surface, .state)
        var result = base(world, surface, target)
        result[field] = state[field] ?? (field == "url" ? "about:blank" : "")
        return .object(result)
    }

    static func eval(_ call: CompatCall) async throws -> JSON {
        let script = try call.require("script")
        let (world, surface, target) = try await browserSurface(call)
        let value: JSON
        do {
            // Objects WebKit cannot return (DOMRect, Map, …) go through toJSON.
            value = try await run(call, surface, .evaluate(CompatBrowserScripts.jsonSafe(script)))
        } catch let error as ControlError where error.code == "js_error" && error.message.contains("SyntaxError") {
            value = try await run(call, surface, .evaluate(script))  // statements, not an expression
        }
        var result = base(world, surface, target)
        result["value"] = value["value"] ?? .null
        return .object(result)
    }

    static func snapshot(_ call: CompatCall) async throws -> JSON {
        let (world, surface, target) = try await browserSurface(call)
        let depth = call.int("max_depth") ?? call.int("maxDepth") ?? 12
        let script = CompatBrowserScripts.snapshot(selector: call.string("selector"), maxDepth: depth,
                                                   interactiveOnly: call.bool("interactive") == true)
        let value = try await run(call, surface, .evaluate(script))["value"] ?? .null
        var result = base(world, surface, target)
        for key in ["snapshot", "title", "url", "ready_state", "refs"] { result[key] = value[key] ?? .null }
        result["page"] = ["title": value["title"] ?? .null, "url": value["url"] ?? .null,
                          "ready_state": value["ready_state"] ?? .null, "text": value["text"] ?? .null]
        return .object(result)
    }

    /// Selector or snapshot ref (`e3`, `@e3`) actions run as page scripts.
    static func action(_ call: CompatCall, _ make: (String, String?) -> String) async throws -> JSON {
        guard let selector = call.string("selector") ?? call.string("ref") ?? call.string("target") else {
            throw CompatErrors.missing("selector", call.method)
        }
        let (world, surface, target) = try await browserSurface(call)
        let text = call.string("text") ?? call.string("value")
        let value = try await run(call, surface, .evaluate(make(selector, text)))["value"] ?? .null
        if let error = value["error"]?.stringValue {
            throw ControlError(code: "not_found", message: error, data: ["selector": .string(selector)])
        }
        var result = base(world, surface, target)
        result["value"] = value["value"] ?? .null
        return .object(result)
    }

    /// New browser tab in a split right of the source pane.
    static func openSplit(_ call: CompatCall) async throws -> JSON {
        let world = try await call.world()
        let source = try call.target(world).pane()
        let sourceSurface = world.surfaces[source.selectedSurfaceUUID ?? ""]
        let handle = try await CompatCreate.split(.browser, from: source, edge: .right, call: call)
        let created = try await CompatCreate.result(call, surface: handle, kind: .browser)
        guard case .object(var result) = created else { return created }
        result["source_surface_id"] = sourceSurface.map { .string($0.uuid) } ?? .null
        result["source_surface_ref"] = sourceSurface.map { .string($0.ref) } ?? .null
        result["source_pane_id"] = .string(source.uuid)
        result["source_pane_ref"] = .string(source.ref)
        result["target_pane_id"] = result["pane_id"]
        result["target_pane_ref"] = result["pane_ref"]
        result["created_split"] = true
        result["placement_strategy"] = "split_right"
        return .object(result)
    }
}
