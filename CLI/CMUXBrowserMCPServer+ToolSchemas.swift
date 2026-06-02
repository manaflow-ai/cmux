import Foundation

extension CMUXBrowserMCPServer {
    func toolDefinitions() -> [[String: Any]] {
        [
            tool(
                "cmux_browser_identify",
                "Inspect cmux context and optional browser surface metadata.",
                objectSchema([
                    "surface": stringSchema("Optional browser surface handle such as surface:2 or a UUID."),
                ])
            ),
            tool(
                "cmux_browser_open",
                "Open a URL in a cmux in-app browser surface, defaulting to the caller workspace.",
                objectSchema([
                    "url": stringSchema("URL to open. Omit to open a blank browser surface."),
                    "workspace": stringSchema("Optional workspace handle."),
                    "window": stringSchema("Optional window handle."),
                    "focus": boolSchema("Whether to focus the new browser surface."),
                ])
            ),
            tool(
                "cmux_browser_navigate",
                "Navigate an existing cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "url": stringSchema("URL to navigate to."),
                    "snapshot_after": boolSchema("Return a post-navigation snapshot when supported."),
                ], required: ["url"])
            ),
            tool(
                "cmux_browser_snapshot",
                "Capture the page accessibility-style snapshot. Interactive refs are enabled by default.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "interactive": boolSchema("Whether to include interactive refs. Defaults to true."),
                    "compact": boolSchema("Use compact snapshot formatting."),
                    "cursor": boolSchema("Include cursor information when supported."),
                    "selector": stringSchema("Optional CSS selector root."),
                    "max_depth": intSchema("Optional maximum tree depth."),
                ])
            ),
            tool(
                "cmux_browser_click",
                "Click a selector or interactive snapshot ref in a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref, such as e3."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector"])
            ),
            tool(
                "cmux_browser_fill",
                "Set an input value. Passing an empty text string clears the input.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref."),
                    "text": stringSchema("Text to set."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector", "text"])
            ),
            tool(
                "cmux_browser_type",
                "Type text into an input or focused element.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector or interactive ref."),
                    "text": stringSchema("Text to type."),
                    "snapshot_after": boolSchema("Return a post-action snapshot when supported."),
                ], required: ["selector", "text"])
            ),
            tool(
                "cmux_browser_wait",
                "Wait for selector, text, URL, load state, or JavaScript condition.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "selector": stringSchema("CSS selector to wait for."),
                    "text": stringSchema("Text to wait for."),
                    "text_contains": stringSchema("Text to wait for."),
                    "url_contains": stringSchema("URL substring to wait for."),
                    "load_state": stringSchema("Load state such as interactive or complete."),
                    "function": stringSchema("JavaScript predicate expression."),
                    "timeout_ms": intSchema("Timeout in milliseconds."),
                ])
            ),
            tool(
                "cmux_browser_get",
                "Read URL, title, text, HTML, value, attr, count, box, or styles from a page.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "kind": enumSchema(["url", "title", "text", "html", "value", "attr", "count", "box", "styles"]),
                    "selector": stringSchema("CSS selector or interactive ref for DOM reads."),
                    "attr": stringSchema("Attribute name for kind=attr."),
                    "property": stringSchema("CSS property for kind=styles."),
                ], required: ["kind"])
            ),
            tool(
                "cmux_browser_eval",
                "Evaluate JavaScript in the cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "script": stringSchema("JavaScript expression or script."),
                ], required: ["script"])
            ),
            tool(
                "cmux_browser_screenshot",
                "Capture a screenshot from the cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "path": stringSchema("Optional output path."),
                    "out": stringSchema("Optional output path alias."),
                ])
            ),
            tool(
                "cmux_browser_console",
                "List or clear captured console messages for a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "action": enumSchema(["list", "clear"]),
                ])
            ),
            tool(
                "cmux_browser_errors",
                "List or clear captured page errors for a cmux browser surface.",
                objectSchema([
                    "surface": stringSchema("Browser surface handle. Defaults to the last opened surface."),
                    "action": enumSchema(["list", "clear"]),
                ])
            ),
            tool(
                "cmux_browser_rpc",
                "Call a raw cmux browser.* socket method for advanced workflows.",
                objectSchema([
                    "method": stringSchema("Allowed method name: browser.* or system.identify."),
                    "params": [
                        "type": "object",
                        "description": "Method parameters.",
                        "additionalProperties": true,
                    ],
                    "timeout_ms": intSchema("Optional response timeout in milliseconds."),
                ], required: ["method"])
            ),
        ]
    }

    func tool(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }

    func objectSchema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    func boolSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    func intSchema(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }
}
