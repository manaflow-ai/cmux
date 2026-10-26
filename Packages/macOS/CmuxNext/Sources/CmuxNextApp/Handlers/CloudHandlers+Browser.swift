import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextCloud
import CmuxNextDaemon
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
            guard session.appLink != nil else { throw ActionFailure(message: CloudPortStrings.classicLink(names)) }
            answer("list machine ports", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID)]) {
                let listed = try await portOp("cloud.port.list", ["machine": .string(session.machineID)], key: nil, names, invocation, context)
                let forwards = (listed["forwards"]?.arrayValue ?? []).map(forwardFields)
                let lines = forwards.compactMap { fields -> String? in
                    guard case .int(let port)? = fields["port"], case .string(let url)? = fields["url"] else { return nil }
                    return "\(port) -> \(url)"
                }
                return CloudAnswer(title: CloudPortStrings.title, text: lines.isEmpty ? CloudPortStrings.none : lines.joined(separator: "\n"),
                                   fields: ["machine_id": .string(session.machineID), "forwards": .array(forwards.map(ActionResultValue.object))])
            }
        }
        bind("cloudPortForward", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "port-forward"), names = CloudPortNames(session, port: port)
            guard session.appLink != nil else { throw ActionFailure(message: CloudPortStrings.classicLink(names)) }
            answer("forward machine port", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port))]
                let forward = forwardFields(try await portOp("cloud.port.forward", args, key: UUID().uuidString.lowercased(), names, invocation, context))
                guard case .string(let url)? = forward["url"] else { throw ActionFailure(message: CloudPortStrings.failed(names, detail: "no local port")) }
                return CloudAnswer(title: CloudPortStrings.title, text: url, fields: forward)
            }
        }
        bind("cloudPortClose", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context), port = try port(invocation, session, verb: "port-close"), names = CloudPortNames(session, port: port)
            guard session.appLink != nil else { throw ActionFailure(message: CloudPortStrings.classicLink(names)) }
            result("close machine port", context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID), "port": .int(port)]) {
                let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port))]
                let closed = try await portOp("cloud.port.close", args, key: UUID().uuidString.lowercased(), names, invocation, context)
                guard closed["closed"]?.boolValue == true else { throw ActionFailure(message: CloudPortStrings.noForward(names)) }
                return ["machine_id": .string(session.machineID), "port": .int(port), "closed": .bool(true)]
            }
        }
        bind("cloudMachineLink", registry, reason: reason) { invocation in
            let invocation = effective(invocation)
            let session = try machine(invocation, context)
            let port = invocation["port"] == nil ? nil : try Self.port(invocation, session, verb: "machine-link")
            let names = CloudPortNames(session, port: port)
            let cloud = context.services.cloud
            answer("machine link", invocation, context, pendingAfter: answerWithin, pending: ["machine_id": .string(session.machineID)]) {
                var fields: [String: ActionResultValue] = ["machine_id": .string(session.machineID), "target": .string("machine:\(session.machineID)")]
                let address = session.machine.address?.ipv4
                guard let port else {
                    if let address { fields["address"] = .string(address) }
                    return CloudAnswer(title: CloudPortStrings.title, text: address ?? "machine:\(session.machineID)", fields: fields)
                }
                fields["port"] = .int(port)
                if let address { fields["private_url"] = .string("http://\(address):\(port)") }
                guard session.machine.allows(.ports) else { throw ActionFailure(message: CloudPortStrings.noLink(names)) }
                let link = try await wrapped(names) { try await cloud.api.openPort(session.machineID, port: port) }
                fields["url"] = .string(link.url)
                if let open = link.openUrl { fields["open_url"] = .string(open) }
                return CloudAnswer(title: CloudPortStrings.title, text: link.openUrl ?? link.url, fields: fields)
            }
        }
    }

    /// Opens `port` (at `path`) of the machine in a Chromium tab and answers the URL and the tab.
    ///
    /// - A machine on the Cloud app server's link: its `cloud.browser.open` route, opened in the
    ///   active window's focused pane through ``BrowserTabOpen`` (the Cloud page's path).
    /// - A machine on the classic link: a tab in the machine's first workspace, whose `localhost`
    ///   the machine's loopback forward serves (remote localhost); the machine connects first.
    @MainActor
    static func openBrowser(_ session: CloudMachineSession, port: Int, path: String, names: CloudPortNames, viewChange: Bool,
                            _ invocation: ActionInvocation, _ context: AppActionContext) async throws -> [String: ActionResultValue] {
        let services = context.services, browserTabs = services.cache.browserTabs
        if let reason = browserTabs.cefUnavailable() {
            throw ActionFailure(message: CloudPortStrings.browserFailed(names, detail: BrowserTabService.message(reason)))
        }
        var fields: [String: ActionResultValue] = ["machine_id": .string(session.machineID), "port": .int(port)]
        if session.appLink != nil {
            let args: [String: JSONValue] = ["machine": .string(session.machineID), "port": .number(Double(port)), "path": .string(path)]
            let route = try await portOp("cloud.browser.open", args, key: UUID().uuidString.lowercased(), names, invocation, context)
            let opened = try await openRoute(route, names: names, background: !viewChange, services: services)
            fields["url"] = route["url"]?.stringValue.map(ActionResultValue.string) ?? .null
            fields["surface_id"] = opened.map { .string(String($0.rawValue)) } ?? .null
            if opened == nil { fields["pending"] = .bool(true) }
            return fields
        }
        let anchor = try await wrapped(names) {
            try await attachedAndConnected(session, invocation)
            return try await terminalAnchor(on: session, context)
        }
        switch services.remoteLocalhost.route(daemon: session.daemon, workspace: anchor.id, engine: .cef) {
        case .machine: break
        case .thisMacInstead(_, .turnedOff): throw ActionFailure(message: CloudPortStrings.localhostOff(names))
        case .thisMacInstead, .thisMac: throw ActionFailure(message: CloudPortStrings.updateMachine(names))
        }
        guard browserTabs.isAvailable(on: session.daemon) else { throw ActionFailure(message: CloudPortStrings.updateMachine(names)) }
        let url = "http://localhost:\(port)\(path)"
        let surface: SurfaceID
        do {
            surface = try await browserTabs.open(BrowserEngineChoice(engine: .cef, pinned: true), in: anchor.pane, url: url,
                                                 activate: viewChange)
        } catch {
            throw ActionFailure(message: CloudPortStrings.browserFailed(names, detail: detail(error)))
        }
        if viewChange { reveal(surface, in: anchor.pane, workspaceID: anchor.id, context) }
        fields["url"] = .string(url)
        fields["workspace_id"] = .string(anchor.id)
        fields["surface_id"] = .string(String(surface.rawValue))
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
        var text = (error as? ActionFailure)?.message ?? (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
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
        guard let port = invocation["port"]?.intValue, (1...65535).contains(port) else {
            throw ActionFailure(message: CloudPortStrings.invalidPort(CloudPortNames(session, port: nil), verb: verb))
        }
        return port
    }

    /// The message of a refused port op.
    static func portFailure(_ failure: CloudAppOpFailure, _ names: CloudPortNames) -> String {
        switch failure.code {
        case "cmux.cloud.port_limit": CloudPortStrings.limit(names)
        default: CloudPortStrings.failed(names, detail: detail(failure))
        }
    }

    /// A forward record of `cloud.port.list` / `cloud.port.forward` as result fields.
    static func forwardFields(_ record: JSONValue) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [:]
        if let machine = record["machine"]?.stringValue { fields["machine_id"] = .string(machine) }
        if let port = record["port"]?.doubleValue { fields["port"] = .int(Int(port)) }
        if let local = record["localPort"]?.doubleValue {
            fields["local_port"] = .int(Int(local))
            fields["url"] = .string("http://127.0.0.1:\(Int(local))/")
        }
        if let state = record["state"]?.stringValue { fields["state"] = .string(state) }
        if let reason = record["reason"]?.stringValue { fields["reason"] = .string(reason) }
        return fields
    }

    /// `--path`: where the tab opens on the port, `/` when absent.
    static func browserPath(_ invocation: ActionInvocation, _ names: CloudPortNames) throws -> String {
        guard let path = invocation["path"]?.stringValue?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return "/" }
        guard path.hasPrefix("/"), path.utf8.count <= 2048, !path.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) else {
            throw ActionFailure(message: CloudPortStrings.pathInvalid(names))
        }
        return path
    }
}
