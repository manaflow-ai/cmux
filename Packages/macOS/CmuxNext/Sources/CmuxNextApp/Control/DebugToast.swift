import AppKit
import CmuxNextActions
import CmuxNextDesign

#if DEBUG
/// `debug.toast`: the toasts of every window, for automation (R96), through
/// the paths a person takes.
/// - `{}` lists each window's toasts (id, message, action title, undo).
/// - `{perform: "<action id>", target_kind?, target_id?, arguments?: {name: string | bool | number}}`
///   runs the action as a person's menu or palette run (`origin: user`), so
///   it gets the questions and the undo toast a person gets; it never
///   answers a question (`debug.dialog` refuses the user-only ones).
/// - `{undo: true, window?}` runs the newest undo toast of the window (the
///   active one by default) as Cmd-Z does.
@MainActor
enum DebugToast {
    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        var result: [String: JSONValue] = [:]
        if let id = params["perform"]?.stringValue {
            var target: ActionTargetRef?
            if let kind = params["target_kind"]?.stringValue.flatMap(ActionTargetKind.init(rawValue:)),
               let targetID = params["target_id"]?.stringValue {
                target = ActionTargetRef(kind: kind, id: targetID)
            }
            var arguments: [String: ActionValue] = [:]
            if case .object(let members)? = params["arguments"] {
                for (name, value) in members {
                    switch value {
                    case .string(let text): arguments[name] = .string(text)
                    case .bool(let flag): arguments[name] = .bool(flag)
                    case .number(let number): arguments[name] = number.rounded() == number ? .int(Int(number)) : .string(String(number))
                    default: continue
                    }
                }
            }
            let invocation = ActionInvocation(target: target, arguments: arguments, origin: .user)
            result["performed"] = .bool(services.registry.perform(ActionID(rawValue: id), invocation: invocation))
        }
        if params["undo"]?.boolValue == true {
            let windowID = params["window"]?.stringValue
            let window = windowID.flatMap { id in services.windows.controllers.first { $0.state.id == id }?.window }
                ?? services.windows.active?.window
            result["undone"] = .bool(window.map { CmuxToastCenter.shared.runUndo(in: $0) } ?? false)
        }
        result["windows"] = .array(services.windows.controllers.map { controller in
            .object([
                "window": .string(controller.state.id),
                "toasts": .array((controller.window.map { CmuxToastCenter.shared.toasts(in: $0) } ?? []).map { toast in
                    .object(["id": .string(toast.id), "message": .string(toast.message),
                             "action": toast.action.map { .string($0.title) } ?? .null,
                             "undo": .bool(toast.action?.isUndo == true)])
                }),
            ])
        })
        return .object(result)
    }
}
#endif
