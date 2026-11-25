import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextRemoteLocalhostService
import Foundation

// A Cloud machine's ports from the CLI, MCP and the palette (audit group H): open one in a
// browser tab, list, forward and close this Mac's forwards, and get a port's link. A CLI or
// agent run answers its result (the URL, the forward, the tab); a person's run opens the tab or
// shows the answer in a sheet. Every failure names the machine and the port and says what to run.
extension CloudHandlers {
    static func bindBrowserActions(into registry: ActionRegistry, context: AppActionContext, reason: @escaping @MainActor () -> String?) {
        bind("cloudOpenBrowser", registry, reason: reason) { original in
            // Read before the origin is normalized, while the run's scope is bound.
            let mayChangeView = viewChange(original)
            let invocation = effective(original)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "open-browser")
            let names = CloudPortNames(session, port: port)
            let path = try browserPath(invocation, names)
            let label = "open machine port in browser"
            if origin(of: invocation) == .user {
                return runTracked(label, context) { _ = try await openBrowser(session, port: port, path: path, names: names, viewChange: mayChangeView, invocation, context) }
            }
            result(label, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                try await openBrowser(session, port: port, path: path, names: names, viewChange: mayChangeView, invocation, context)
            }
        }
        bind("cloudPortList", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), names = CloudPortNames(session, port: nil)
            answer("list machine ports", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID)]) {
                let listed = try await portOp("cloud.port.list", ["machine": .string(session.machineID)], key: nil, names, invocation, context)
                let forwards = (listed["forwards"]?.arrayValue ?? []).map(CloudHandlerRules.any)
                return cloudAnswer(CloudPortStrings.title, CloudHandlerRules().answer(["kind": "portList", "machineId": session.machineID, "forwards": forwards]),
                                   none: CloudPortStrings.none)
            }
        }
        bind("cloudPortForward", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "port-forward"), names = CloudPortNames(session, port: port)
            answer("forward machine port", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port))]
                let record = CloudHandlerRules.any(try await portOp("cloud.port.forward", args, key: UUID().uuidString.lowercased(), names, invocation, context))
                let rules = CloudHandlerRules()
                let reply = try rules.answered("cloud_handler_forward", ["record": record, "names": CloudHandlerRules.json(names)])
                return cloudAnswer(CloudPortStrings.title, CloudHandlerRules.answer(reply))
            }
        }
        bind("cloudPortClose", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "port-close"), names = CloudPortNames(session, port: port)
            result("close machine port", context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port))]
                let closed = try await portOp("cloud.port.close", args, key: UUID().uuidString.lowercased(), names, invocation, context)
                guard closed["closed"]?.boolValue == true else { throw ActionFailure(message: CloudPortStrings.noForward(names)) }
                return ["machine_id": .string(session.machineID), "port": .int(port), "closed": .bool(true)]
            }
        }
        bind("cloudPreviewShare", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "preview-share")
            let names = CloudPortNames(session, port: port)
            answer("share machine preview", invocation, context, pendingAfter: answerWithin,
                   pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                let created = try await previewShareLink(context.services.cloud.previewAPI, machine: session.machineID, port: port, names: names)
                context.copy(created.url)
                return CloudAnswer(title: CloudPortStrings.previewLinkCopied, text: created.url, fields: [
                    "machine_id": .string(session.machineID), "port": .int(port),
                    "linkId": .string(created.link.linkId), "url": .string(created.url),
                    "expiresAt": .int(created.link.expiresAt), "redemptions": .int(created.link.redemptions),
                ])
            }
        }
        bind("cloudPreviewRevoke", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "preview-revoke")
            let names = CloudPortNames(session, port: port)
            let linkID = try CloudHandlerRules().text("linkId", invocation, port: names)
            answer("revoke machine preview link", invocation, context, pendingAfter: answerWithin,
                   pending: ["machine_id": .string(session.machineID), "port": .int(port), "linkId": .string(linkID)]) {
                guard let api = context.services.cloud.previewAPI else { throw ActionFailure(message: CloudPortStrings.noLink(names)) }
                let revoked = try await wrapped(names) { try await api.revokePreviewShareLink(session.machineID, port: port, linkID: linkID) }
                return CloudAnswer(title: CloudPortStrings.previewLinkRevoked,
                                   text: revoked.revoked ? CloudPortStrings.previewLinkRevoked : CloudPortStrings.previewLinkAlreadyRevoked,
                                   fields: [
                    "machine_id": .string(session.machineID), "port": .int(port), "linkId": .string(linkID), "revoked": .bool(true),
                ])
            }
        }
        bind("cloudMachineLink", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context)
            let port = invocation["port"] == nil ? nil : try Self.port(invocation, session, verb: "machine-link")
            let names = CloudPortNames(session, port: port)
            answer("machine link", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID)]) {
                let rules = CloudHandlerRules()
                var facts: [String: Any] = ["names": CloudHandlerRules.json(names), "ipv4": session.machine.address?.ipv4 as Any,
                                            "allowsPorts": session.machine.allows(.ports)]
                if let port {
                    // A provider that opens no port links is refused before the platform makes one.
                    _ = try rules.checked("cloud_handler_machine_link_port", facts.compacted)
                    let link = try await previewShareLink(context.services.cloud.previewAPI, machine: session.machineID, port: port, names: names)
                    facts["link"] = ["url": link.url, "linkId": link.link.linkId, "expiresAt": link.link.expiresAt]
                }
                return cloudAnswer(CloudPortStrings.title, CloudHandlerRules.answer(try rules.answered("cloud_handler_machine_link", facts.compacted)))
            }
        }
    }

    /// `port`'s link (Copy Link, `cloud machine-link --port`, `cloud preview-share`): the platform's
    /// anonymous, expiring share link (`POST /v1/cloud/machines/{id}/previews/{port}/links`), https
    /// only. With no platform preview origin (`api` nil) there is none.
    @MainActor
    static func previewShareLink(_ api: CloudAPIClient?, machine: String, port: Int, names: CloudPortNames) async throws -> CloudPreviewShareLinkCreated {
        guard let api else { throw ActionFailure(message: CloudPortStrings.noLink(names)) }
        let created = try await wrapped(names) { try await api.createPreviewShareLink(machine, port: port) }
        let checked = CloudHandlerRules().ask("cloud_handler_share_link", ["url": created.url, "names": CloudHandlerRules.json(names)])
        guard checked?["ok"] as? Bool == true else {
            throw CloudHandlerRules.failure(CloudHandlerRules.decodeSaid(checked?["refusal"] ?? NSNull()))
        }
        return created
    }

    /// Opens `port` (at `path`) of the machine in a Chromium tab and answers the URL and the tab.
    ///
    /// With the platform's preview API, its authenticated preview URL, opened in the active
    /// window's focused pane; else the app server's `cloud.browser.open` route.
    @MainActor
    static func openBrowser(_ session: CloudMachineSession, port: Int, path: String, names: CloudPortNames, viewChange: Bool,
                            _ invocation: ActionInvocation, _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        let services = context.services, browserTabs = services.cache.browserTabs
        if let reason = browserTabs.cefUnavailable() {
            throw ActionFailure(message: CloudPortStrings.browserFailed(names, detail: BrowserTabService.message(reason)))
        }
        var fields: [String: ActionResultValue] = ["machine_id": .string(session.machineID), "port": .int(port)]
        if services.cloud.previewAPI != nil {
            let inventory = try await refreshPreviews(session, names, context)
            guard let preview = inventory.previews.first(where: { $0.port == port }) else {
                throw ActionFailure(message: CloudPortStrings.failed(names, detail: CloudPortStrings.noPreviews))
            }
            return try await openPreview(preview, session: session, path: path, viewChange: viewChange, context)
        }
        let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port)), "path": .string(path)]
        let route = try await portOp("cloud.browser.open", args, key: UUID().uuidString.lowercased(), names, invocation, context)
        let opened = try await openRoute(route, names: names, background: !viewChange, services: services)
        fields["url"] = route["url"]?.stringValue.map(ActionResultValue.string) ?? .null
        fields["surface_id"] = opened.map { .string(String($0.rawValue)) } ?? .null
        if opened == nil { fields["pending"] = .bool(true) }
        return fields
    }

    /// Opens a `cloud.browser.open` route's tab and answers its surface, or nil when the daemon has
    /// not made the tab within ``browserTabWait`` (it may still land).
    @MainActor
    private static func openRoute(_ route: JSONValue, names: CloudPortNames, background: Bool, services: AppServices) async throws -> SurfaceID? {
        let (surfaces, continuation) = AsyncStream<SurfaceID?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let refusal: String?
        do throws(BrowserTabOpen.Refusal) {
            let request = try BrowserTabOpen.request(route: pageJSON(route), machineName: names.name)
            refusal = try await BrowserTabOpen.open(request, services: services, background: background, reportsRefusal: true) { continuation.yield($0) }
        } catch {
            continuation.finish()
            let detail = error == .cefUnavailable ? RefusalStrings.chromiumUnavailable : CloudPortStrings.routeRefused(error.code)
            throw ActionFailure(message: error == .noWindow ? CloudPortStrings.noWindow(names) : CloudPortStrings.browserFailed(names, detail: detail))
        }
        if let refusal {
            continuation.finish()
            throw ActionFailure(message: CloudPortStrings.browserFailed(names, detail: refusal))
        }
        // task-owner: the surface deadline; cancelled below once the daemon answered.
        let deadline = Task {
            // wakeup-allow: one-shot deadline for the daemon's new tab; cancelled when it lands first
            try? await Task.sleep(for: browserTabWait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await surface in surfaces { return surface }
        return nil
    }

    /// How long `open-browser` waits for the new tab's surface before it answers `pending`:
    /// inside `action.run`'s 40 s result deadline, after the route's own round trip.
    static let browserTabWait: Duration = .seconds(15)

    /// One Cloud app server port op. Its refusal names the machine and the port.
    @MainActor
    private static func portOp(_ op: String, _ args: [String: JSONValue], key: String?, _ names: CloudPortNames,
                               _ invocation: ActionInvocation, _ context: AppActionContext) async throws -> JSONValue {
        do {
            return try await context.services.cloud.appOps(op, .object(args), key, invocation.origin == .user ? .user : .script)
        } catch let failure as CloudAppOpFailure {
            throw ActionFailure(message: portFailure(failure, names))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionFailure(message: CloudPortStrings.failed(names, detail: detail(error)))
        }
    }

    /// `work`, whose failure (a link that never came up, an API error) names the machine and the port.
    @MainActor
    static func wrapped<T>(_ names: CloudPortNames, _ work: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ActionFailure(message: CloudPortStrings.failed(names, detail: detail(error)))
        }
    }

    /// An error's own words, without a trailing period (it sits inside a sentence).
    static func detail(_ error: any Error) -> String {
        let text = (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        let said = CloudHandlerRules.decodeSaid(CloudHandlerRules().ask("cloud_handler_port_failure", ["text": text])?["refusal"] ?? NSNull())
        // `portFailed` names the machine and port first; its detail is last.
        return said.key == "portFailed" ? said.args.last ?? text : text
    }

    /// The run with its outermost caller's origin (``ActionRunScope``): a nested run of a script
    /// connects and calls the app server as the script, never as the person.
    static func effective(_ invocation: ActionInvocation) -> ActionInvocation {
        var effective = invocation
        effective.origin = origin(of: invocation)
        return effective
    }

    /// Whether the run may change the view: its own permission (a person's gesture, `--focus`),
    /// and its outer run's when it is nested (``ActionRunScope``).
    static func viewChange(_ invocation: ActionInvocation) -> Bool {
        invocation.allowsViewChange && ActionRunScope.viewChangeAllowed()
    }

    /// A CLI or agent run answers within `action.run`'s result deadline: a slow link or app op
    /// answers `pending` then, and the work goes on.
    static let answerWithin: Duration = ActionDescriptor.resultDeadline - .seconds(5)

    /// `--port`, refused with the machine named and the command to run.
    static func port(_ invocation: ActionInvocation, _ session: CloudMachineSession, verb: String) throws -> Int {
        try CloudHandlerRules().namedPort(invocation, CloudPortNames(session, port: nil), verb: verb)
    }

    /// The message of a refused port op.
    static func portFailure(_ failure: CloudAppOpFailure, _ names: CloudPortNames) -> String {
        let text = (failure as? any LocalizedError)?.errorDescription ?? String(describing: failure)
        let facts: [String: Any] = ["code": failure.code as Any, "text": text, "names": CloudHandlerRules.json(names)]
        let said = CloudHandlerRules().ask("cloud_handler_port_failure", facts.compacted)?["refusal"] ?? NSNull()
        return CloudHandlerRules.text(CloudHandlerRules.decodeSaid(said))
    }

    /// `--path`: where the tab opens on the port, `/` when absent.
    static func browserPath(_ invocation: ActionInvocation, _ names: CloudPortNames) throws -> String {
        try CloudHandlerRules().text("browserPath", invocation, port: names)
    }
}

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
            let choice = await CmuxDialogCenter.shared.present(CloudPreviewPresentation(inventory).picker(machineName: session.machine.title, cancelTitle: CloudStrings.cancel), in: .window(window))
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

    static func previewAnswer(_ inventory: CloudMachinePreviews) -> CloudAnswer {
        let presentation = CloudPreviewPresentation(inventory)
        return CloudAnswer(title: CloudPortStrings.title, text: presentation.text,
                           copyable: presentation.copyable, fields: presentation.fields)
    }

    /// A platform preview is an HTTPS website, independent of the Mac's loopback proxy routes.
    static func openPreview(_ preview: CloudMachinePreview, session: CloudMachineSession, path: String = "/", viewChange: Bool,
                            _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        let names = CloudPortNames(session, port: preview.port)
        guard let pane = context.services.windows.active?.focusedPane?.pane else { throw ActionFailure(message: CloudPortStrings.noWindow(names)) }
        let url = try await wrapped(names) { try preview.browserURL(path: path) }
        let surface = try await wrapped(names) {
            try await context.services.cache.browserTabs.open(BrowserEngineChoice(engine: .cef, pinned: true),
                                                              in: pane, url: url.absoluteString, activate: viewChange)
        }
        return ["machine_id": .string(session.machineID), "port": .int(preview.port), "url": .string(url.absoluteString),
                "origin": .string(preview.origin), "surface_id": .string(String(surface.rawValue))]
    }
}

extension CloudPortNames {
    @MainActor init(_ session: CloudMachineSession, port: Int?) {
        self.init(name: session.machine.title, id: session.machineID, port: port)
    }

}
