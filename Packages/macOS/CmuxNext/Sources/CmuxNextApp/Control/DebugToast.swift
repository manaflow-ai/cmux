import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.toast`: the toasts of every window, for automation (R96), through
/// the paths a person takes.
/// - `{}` lists each window's toasts (id, message, action title, undo).
/// - `{perform: "<action id>", target_kind?, target_id?, arguments?: {name: string | bool | number}}`
///   runs the action as a person's menu or palette run (`origin: user`), so
///   it gets the questions and the undo toast a person gets; it never
///   answers a question (`debug.dialog` refuses the user-only ones).
/// - `{undo: true, window?}` runs the newest undo toast of the window (the
///   active one by default) as Cmd-Z does.
/// - `{press: "<toast id>", window?}` runs the action of the newest toast
///   with that id, as its button does.
/// Every reply also has `undo_steps`: the sidebar and pin undo steps registered so far.
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
                    case .number(let number): arguments[name] = number.rounded() == number ? ActionValue.int(Int(number)) : ActionValue.string(String(number))
                    default: continue
                    }
                }
            }
            let invocation = ActionInvocation(target: target, arguments: arguments, origin: .user)
            result["performed"] = .bool(services.registry.perform(ActionID(rawValue: id), invocation: invocation))
        }
        let windowID = params["window"]?.stringValue
        let window = windowID.flatMap { id in services.windows.controllers.first { $0.state.id == id }?.window }
            ?? services.windows.active?.window
        if params["undo"]?.boolValue == true {
            // As Cmd-Z: the newest undo toast, else the window's undo stack (moves and pins have no toast).
            result["undone"] = .bool(window.map { window in
                if CmuxToastCenter.shared.runUndo(in: window) { return true }
                guard let manager = window.undoManager, manager.canUndo else { return false }
                manager.undo()
                return true
            } ?? false)
        }
        if let toastID = params["press"]?.stringValue {
            result["pressed"] = .bool(window.map { CmuxToastCenter.shared.runAction(id: toastID, in: $0) } ?? false)
        }
        var windows: [JSONValue] = []
        for controller in services.windows.controllers {
            let toasts = controller.window.map { CmuxToastCenter.shared.toasts(in: $0) } ?? []
            windows.append(.object(["window": .string(controller.state.id), "toasts": .array(toasts.map(report))]))
        }
        result["windows"] = .array(windows)
        // Every refusal HUD message so far, newest last.
        result["refusals"] = .array(services.refusalHUD.history.map(JSONValue.string))
        // Sidebar and pin undo steps registered so far (a change's step comes with its daemon reply, after the change shows).
        result["undo_steps"] = .number(Double(PinUndoStep.registered))
        return .object(result)
    }

    private static func report(_ toast: CmuxToast) -> JSONValue {
        let action: JSONValue = toast.action.map { .string($0.title) } ?? .null
        return .object(["id": .string(toast.id), "message": .string(toast.message), "action": action,
                        "undo": .bool(toast.action?.isUndo == true)])
    }
}
#endif
