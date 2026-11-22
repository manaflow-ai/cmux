import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextSettings

#if DEBUG
/// `debug.dialog`: every open cmux dialog for automation (R96), through the
/// same center path a click takes.
/// - `{}` lists the open dialogs (id, title, lines, origin, scope, visible,
///   buttons, field values, frame in window coordinates).
/// - `{open: "confirm" | "text" | "credentials" | "save" | "choice", scope: "window" | "app", origin?}`
///   shows a fixture (screenshots, latency) and returns its id.
/// - `{id?, set: {field: string | bool}}`, `{id?, key: "return" | "escape" | "tab" | "shift-tab" | "cmd-<c>"}`,
///   `{id?, press: "<button>"}`, `{id?, dismiss: true}` act on dialog `id`
///   (default: the newest visible one).
@MainActor
enum DebugDialog {
    /// Dialogs only the user answers: a clipboard read (CLIPBOARD-READ-BROKER) and the Enable
    /// harness sheet (a folder's program would run with the user's rights).
    static let userOnly: Set<String> = [ClipboardReadStrings.identifier, AgentPaneView.harnessEnableIdentifier]

    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let center = CmuxDialogCenter.shared
        var result: [String: JSONValue] = [:]
        if let fixture = params["open"]?.stringValue {
            guard let spec = fixtures(origin: params["origin"]?.stringValue)[fixture] else {
                return .object(["error": .string("unknown fixture \(fixture)")])
            }
            let window = services.windows.active?.window
            let scope: CmuxDialogScope = if params["scope"]?.stringValue != "app", let window { .window(window) } else { .app }
            result["opened"] = .number(Double(center.present(spec, in: scope) { _ in }))
        }
        let target = params["id"]?.intValue ?? center.records.last(where: \.visible)?.id
        // Only the user answers a clipboard read (CLIPBOARD-READ-BROKER);
        // automation may dismiss it, which refuses the read.
        if let target, let identifier = center.record(target)?.spec.identifier, userOnly.contains(identifier),
           params["set"] != nil || params["key"] != nil || params["press"] != nil {
            result["error"] = .string("this dialog answers only to the user")
        } else if let target {
            if case .object(let fields)? = params["set"] {
                for (field, value) in fields {
                    let typed: CmuxDialogValue? = value.boolValue.map(CmuxDialogValue.bool) ?? value.stringValue.map(CmuxDialogValue.text)
                    result["set.\(field)"] = .bool(typed.map { center.setValue($0, for: field, in: target) } ?? false)
                }
            }
            if let name = params["key"]?.stringValue {
                result["key"] = .bool(key(name).map { center.key($0.0, modifiers: $0.1, in: target) } ?? false)
            }
            if let button = params["press"]?.stringValue { result["pressed"] = .bool(center.press(target, button: button)) }
            if params["dismiss"]?.boolValue == true { result["dismissed"] = .bool(center.dismiss(target)) }
        }
        result["dialogs"] = .array(center.records.map { report($0, view: center.view($0.id)) })
        return .object(result)
    }

    private static func key(_ name: String) -> (CmuxDialogKeys.Key, CmuxDialogKeys.Modifiers)? {
        switch name {
        case "return": return (.return, [])
        case "escape": return (.escape, [])
        case "tab": return (.tab, [])
        case "shift-tab": return (.tab, .shift)
        default:
            guard name.hasPrefix("cmd-"), name.count == 5, let character = name.last else { return nil }
            return (.character(character), .command)
        }
    }

    private static func report(_ record: CmuxDialogCenter.Record, view: CmuxDialogView?) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for (field, value) in record.values {
            switch value {
            case .text(let text): values[field] = .string(text)
            case .bool(let on): values[field] = .bool(on)
            }
        }
        var object: [String: JSONValue] = [
            "id": .number(Double(record.id)), "title": .string(record.spec.title),
            "identifier": record.spec.identifier.map { .string($0) } ?? .null,
            "lines": .array(record.spec.lines.map { .string($0) }), "scope": .string(record.scope),
            "visible": .bool(record.visible), "values": .object(values),
            "buttons": .array(record.spec.buttons.map { button in
                .object(["id": .string(button.id), "title": .string(button.title), "role": .string(button.role.rawValue),
                         "key": button.key.map { .string(String($0)) } ?? .null])
            }),
        ]
        if let origin = record.spec.origin { object["origin"] = .string(origin) }
        if let view, view.window != nil {
            let frame = view.convert(view.bounds, to: nil)
            object["frame"] = .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
            object["window"] = .number(Double(view.window?.windowNumber ?? 0))
        }
        return .object(object)
    }

    /// Debug-only fixtures (English only: they never ship).
    private static func fixtures(origin: String?) -> [String: CmuxDialogSpec] {
        [
            "confirm": CmuxDialogSpec(title: "Close Workspace “api”?", lines: ["vim and npm are still running."],
                                      buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .destructive)],
                                      identifier: "cmux.dialog.fixture.confirm"),
            "text": CmuxDialogSpec(title: "Rename Tab", fields: [.text("name", initial: "zsh")],
                                   buttons: [.cancel(), CmuxDialogButton(id: "rename", title: "Rename", role: .default)],
                                   identifier: "cmux.dialog.fixture.text"),
            "credentials": CmuxDialogSpec(
                title: "Sign in to example.com", lines: ["The server asks for a user name and password."],
                origin: origin ?? "https://example.com",
                fields: [.text("user", label: "User Name"),
                         .text(id: "password", label: "Password", initial: "", placeholder: nil, secure: true)],
                buttons: [.cancel(), CmuxDialogButton(id: "sign-in", title: "Sign In", role: .default)],
                identifier: "cmux.dialog.fixture.credentials"),
            "save": CmuxDialogSpec(title: "Save changes to “notes.md”?", lines: ["Your changes are lost if you do not save them."],
                                   buttons: [CmuxDialogButton(id: "dont-save", title: "Don't Save", role: .destructive, key: "d"),
                                             .cancel(), CmuxDialogButton(id: "save", title: "Save", role: .default)],
                                   identifier: "cmux.dialog.fixture.save"),
            "choice": CmuxDialogSpec(title: "Choose a Region", fields: [
                .choice(id: "region", label: nil, options: [CmuxDialogOption(label: "US West", value: "us-west"),
                                                            CmuxDialogOption(label: "EU Central", value: "eu-central")],
                        selected: "us-west"),
                .check(id: "remember", title: "Don't ask again", on: false),
            ], buttons: [.cancel(), CmuxDialogButton(id: "select", title: "Select", role: .default)],
            identifier: "cmux.dialog.fixture.choice"),
        ]
    }
}
#endif
