import CmuxNextPages
import CmuxNextSettings
import Foundation

/// A workspace's own background, from the art picker's This Workspace choice (cx-t2x.5).
struct SettingsWorkspaceBackgrounds {
    /// The workspace's name, nil when it is gone.
    let title: @MainActor (_ workspace: String) -> String?
    /// Its own background, nil when it follows `appearance.background`.
    let value: @MainActor (_ workspace: String) -> String?
    let set: @MainActor (_ value: String?, _ workspace: String) -> Void
    /// Shows a value without saving it; the outer nil ends the preview.
    let preview: @MainActor (_ value: String??, _ workspace: String) -> Void
    /// Its own glass tint over art (the picker's This Workspace Opacity).
    var opacity: SettingsWorkspaceOpacity?
}

/// A workspace's own glass tint over art, 0...1; nil follows the work's own tint.
struct SettingsWorkspaceOpacity {
    let value: @MainActor (_ workspace: String) -> Double?
    let set: @MainActor (_ value: Double?, _ workspace: String) -> Void
    /// Shows a tint without saving it; the outer nil ends the preview.
    let preview: @MainActor (_ value: Double??, _ workspace: String) -> Void
}

extension SettingsPageProvider {
    /// `cmux.settings.backdrop.workspace` reads a workspace's background and tint; `.set` saves one
    /// (`value`, or `opacity` when given; null follows the app's; a user gesture); `.preview` shows
    /// one (`end: true` stops both).
    func workspaceBackground(_ op: String, params: JSONValue, context: PageCallContext) throws -> JSONValue {
        guard let workspaceBackgrounds else { throw PageError(code: "cmux.page.unavailable", message: "no workspace backgrounds") }
        guard let workspace = params["workspace"]?.stringValue, let title = workspaceBackgrounds.title(workspace) else {
            throw PageError.invalidParams("workspace is required")
        }
        if op == "cmux.settings.backdrop.workspace" {
            return ["workspace": .string(workspace), "title": .string(title),
                    "value": workspaceBackgrounds.value(workspace).map(JSONValue.string) ?? .null,
                    "opacity": workspaceBackgrounds.opacity?.value(workspace).map(JSONValue.number) ?? .null]
        }
        // A preview writes nothing, so like `cmux.settings.preview` it needs no gesture: a dwell is
        // a pointer move, and closing Settings ends it long after the last click.
        let preview = op == "cmux.settings.backdrop.workspace.preview"
        guard preview || context.userGesture else {
            throw PageError(code: "cmux.page.gesture", message: "a workspace background needs a user gesture")
        }
        if preview, params["end"] == .bool(true) {
            workspaceBackgrounds.preview(nil, workspace)
            workspaceBackgrounds.opacity?.preview(nil, workspace)
            return .object([:])
        }
        if let given = params["opacity"] {
            guard let opacity = workspaceBackgrounds.opacity else { throw PageError(code: "cmux.page.unavailable", message: "no workspace opacity") }
            var tint: Double?
            if given != .null {
                guard let number = given.doubleValue, (0...1).contains(number) else {
                    throw PageError(code: "cmux.settings.invalid", message: "opacity is 0...1")
                }
                tint = number
            }
            if preview { opacity.preview(.some(tint), workspace) } else { opacity.set(tint, workspace) }
            return .object([:])
        }
        // JSONValue takes `nil` as its own `.null`, so a null value is dropped by a pattern.
        var value: JSONValue?
        if let given = params["value"], given != .null { value = given }
        if let value {
            guard let descriptor = SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath), descriptor.accepts(value) else {
                throw PageError(code: "cmux.settings.invalid", message: "not a background: \(value)")
            }
        }
        let background = value?.stringValue
        if preview {
            workspaceBackgrounds.preview(.some(background), workspace)
        } else {
            workspaceBackgrounds.set(background, workspace)
        }
        return .object([:])
    }
}
