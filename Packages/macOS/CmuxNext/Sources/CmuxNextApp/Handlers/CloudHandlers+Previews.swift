import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

extension CloudHandlers {
    /// The same detected-port inventory serves the machine menu, palette, CLI and MCP.
    static func livePreviewPorts(_ session: CloudMachineSession, _ invocation: ActionInvocation, _ context: AppActionContext) {
        let names = CloudPortNames(session, port: nil)
        if origin(of: invocation) != .user {
            return answer("machine previews", invocation, context, pendingAfter: answerWithin) {
                previewAnswer(try await refreshPreviews(session, names, context))
            }
        }
        runTracked("machine previews", context) {
            let inventory = try await refreshPreviews(session, names, context)
            guard !inventory.previews.isEmpty else {
                CloudPresenter.show(CloudPortStrings.title, CloudPortStrings.noPreviews, in: window(context))
                return
            }
            guard let window = window(context) else { throw ActionFailure(message: CloudPortStrings.noWindow(names)) }
            let choice = await CmuxDialogCenter.shared.present(previewPicker(inventory, machineName: session.machine.title), in: .window(window))
            guard choice.button == "open", !choice.isDismissal, let port = choice.text("port").flatMap(Int.init),
                  let preview = inventory.previews.first(where: { $0.port == port }) else { return }
            // A person can leave the picker open longer than the bootstrap credential lives.
            if preview.expiresAt <= Date().timeIntervalSince1970 * 1000 {
                _ = try await openBrowser(session, port: port, path: "/", names: CloudPortNames(session, port: port),
                                          viewChange: true, invocation, context)
            } else {
                _ = try await openPreview(preview, session: session, viewChange: true, context)
            }
        }
    }

    static func refreshPreviews(_ session: CloudMachineSession, _ names: CloudPortNames, _ context: AppActionContext) async throws -> CloudMachinePreviews {
        guard let api = context.services.cloud.previewAPI else { throw ActionFailure(message: CloudPortStrings.noLink(names)) }
        let inventory = try await wrapped(names) { try await api.refreshPreviews(session.machineID) }
        guard inventory.machine == session.machineID else {
            throw ActionFailure(message: CloudPortStrings.failed(names, detail: CloudPortStrings.routeRefused("machine.preview_wrong_machine")))
        }
        return inventory
    }

    static func previewPicker(_ inventory: CloudMachinePreviews, machineName: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: CloudPortStrings.title, lines: [machineName], fields: [
            .choice(id: "port", label: nil,
                    options: inventory.previews.map { CmuxDialogOption(label: "\($0.port) · \($0.origin)", value: String($0.port)) },
                    selected: inventory.previews.first.map { String($0.port) }),
        ], buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "open", title: CloudPortStrings.openPreview, role: .default)],
        identifier: "cmux.dialog.cloud.livePreviews")
    }

    static func previewAnswer(_ inventory: CloudMachinePreviews) -> CloudAnswer {
        let lines = inventory.previews.map { "\($0.port) → \($0.url)" }
        return CloudAnswer(title: CloudPortStrings.title, text: lines.isEmpty ? CloudPortStrings.noPreviews : lines.joined(separator: "\n"),
                           copyable: !lines.isEmpty, fields: [
            "machine_id": .string(inventory.machine),
            "ports": .string(inventory.listening.map(String.init).joined(separator: ",")),
            "listening": .array(inventory.listening.map(ActionResultValue.int)),
            "previews": .array(inventory.previews.map { .object([
                "port": .int($0.port), "url": .string($0.url), "origin": .string($0.origin), "expiresAt": .double($0.expiresAt),
            ]) }),
            "unavailable": .array(inventory.unavailable.map { .object(["port": .int($0.port), "code": .string($0.code)]) }),
        ])
    }

    /// A platform preview is an HTTPS website, independent of the Mac's loopback proxy routes.
    static func openPreview(_ preview: CloudMachinePreview, session: CloudMachineSession, path: String = "/", viewChange: Bool,
                            _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        let names = CloudPortNames(session, port: preview.port)
        guard let pane = context.services.windows.active?.focusedPane else { throw ActionFailure(message: CloudPortStrings.noWindow(names)) }
        let url = try await wrapped(names) { try preview.browserURL(path: path) }
        let surface = try await wrapped(names) {
            try await context.services.cache.browserTabs.open(BrowserEngineChoice(engine: .cef, pinned: true),
                                                              in: pane, url: url.absoluteString, activate: viewChange)
        }
        return ["machine_id": .string(session.machineID), "port": .int(preview.port), "url": .string(url.absoluteString),
                "origin": .string(preview.origin), "surface_id": .string(String(surface.rawValue))]
    }
}
