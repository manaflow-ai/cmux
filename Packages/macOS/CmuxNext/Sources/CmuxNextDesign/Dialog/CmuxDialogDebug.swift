import AppKit

#if DEBUG || CMUX_BENCH_HOOKS
/// Shared dialog probes and inert fixtures. Reports redact every secure text field;
/// the app supplies feature-specific fixtures and the policy for user-only dialogs.
@MainActor
package struct CmuxDialogDebug {
    package init() {}

    /// Text fields whose value a report never shows (a password, a vault secret): their ids per dialog.
    package func secureFields(_ spec: CmuxDialogSpec) -> Set<String> {
        Set(spec.fields.compactMap { field in
            if case .text(let id, _, _, _, true) = field { return id }
            return nil
        })
    }

    package func key(_ name: String) -> (CmuxDialogKeys.Key, CmuxDialogKeys.Modifiers)? {
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

    package func report(_ record: CmuxDialogCenter.Record, view: CmuxDialogView?) -> [String: Any] {
        var values: [String: Any] = [:]
        let secure = secureFields(record.spec)
        for (field, value) in record.values {
            switch value {
            case .text(let text): values[field] = secure.contains(field) ? (text.isEmpty ? "" : "<hidden>") : text
            case .bool(let on): values[field] = on
            }
        }
        var object: [String: Any] = [
            "id": record.id, "title": record.spec.title,
            "identifier": record.spec.identifier.map { $0 as Any } ?? NSNull(),
            "lines": record.spec.lines, "scope": record.scope,
            "visible": record.visible, "values": values,
            "buttons": record.spec.buttons.map { button -> [String: Any] in
                ["id": button.id, "title": button.title, "role": button.role.rawValue,
                 "key": button.key.map { String($0) as Any } ?? NSNull()]
            },
        ]
        if let origin = record.spec.origin { object["origin"] = origin }
        // Each choice field's options (label and value), so a check can read what a menu offers.
        var options: [String: Any] = [:]
        for case .choice(let id, _, let choices, _) in record.spec.fields {
            options[id] = choices.map { ["label": $0.label, "value": $0.value] }
        }
        if !options.isEmpty { object["options"] = options }
        if let view, view.window != nil {
            let frame = view.convert(view.bounds, to: nil)
            object["frame"] = [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
            object["window"] = view.window?.windowNumber ?? 0
        }
        return object
    }

    package func fixtures(origin: String?) -> [String: CmuxDialogSpec] {
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
