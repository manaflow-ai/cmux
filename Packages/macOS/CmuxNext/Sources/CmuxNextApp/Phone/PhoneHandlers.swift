import AppKit
import CmuxNextActions
import CmuxNextPhone

/// The phone actions (PhoneActionCatalog): palette, `cmux phone ...` and the
/// `app_phone_*` MCP tools all run these, over the one ``PhoneService``.
/// Work that waits on simctl or devicectl is tracked, so a CLI or MCP run
/// answers when it is done and gets its failure.
enum PhoneHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let page = PhonePageTab(phones: services.phones)
        services.pages.register(page) // at launch, so a restored tab finds it
        services.phones.feedbackSink = services.phoneFeedback

        func work(_ id: ActionID, _ body: @escaping @MainActor (ActionInvocation, PhoneService) async throws -> Void) {
            registry.bind(id, run: { invocation in
                let phones = services.phones
                registry.track(Task { @MainActor in
                    do {
                        try await body(invocation, phones)
                        return nil
                    } catch {
                        let reason = (error as? PhoneError)?.description ?? String(describing: error)
                        registry.refuse(reason)
                        return ActionWorkFailure(stringLiteral: reason)
                    }
                })
            })
        }

        work("phone.show") { invocation, phones in
            let device = try await device(invocation, phones)
            if page.view(showing: device.id) == nil { page.nextDevice = device.id }
            // One phone tab per window: an open tab switches to the named phone.
            let shown = services.pages.show(.phone, in: services.windows.active, focus: invocation.allowsViewChange)
            page.nextDevice = nil
            if shown == nil { throw PhoneError.unsupported(mode: device.mode, what: "a phone tab without a window") }
            page.anyView?.select(device.id)
        }
        work("phone.boot") { invocation, phones in
            try await phones.boot(try await device(invocation, phones).id)
        }
        /// Work that answers fields (`action.run` `result`), so the CLI and MCP get data back.
        func answer(_ id: ActionID, _ body: @escaping @MainActor (ActionInvocation, PhoneService) async throws -> [String: ActionResultValue]) {
            registry.bind(id, run: { invocation in
                let phones = services.phones
                // task-owner: the action run; a capturing caller awaits it through the registry.
                registry.track(result: Task { @MainActor in
                    do {
                        return .success(try await body(invocation, phones))
                    } catch {
                        let reason = (error as? PhoneError)?.description ?? String(describing: error)
                        registry.refuse(reason)
                        return .failure(ActionWorkFailure(stringLiteral: reason))
                    }
                })
            })
        }

        answer("phone.screenshot") { invocation, phones in
            let device = try await device(invocation, phones)
            let file = invocation["path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let saved = try await phones.screenshot(device.id, to: file)
            if invocation.origin == .user { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved.path, forType: .string) }
            return ["path": .string(saved.path), "device": .string(device.id.description)]
        }
        answer("phone.list") { _, phones in
            let listed = try await phones.reload()
            let rows = listed.map { device -> [String: Any] in
                ["id": device.id.description, "name": device.name, "model": device.model, "os": device.osVersion,
                 "ready": device.state.isReady, "capabilities": phones.capabilities(device).names]
            }
            var result: [String: ActionResultValue] = ["count": .int(listed.count), "devices": .string(try json(rows))]
            let missing = await phones.missingTools.map(\.rawValue).sorted()
            if !missing.isEmpty { result["missing"] = .string(missing.joined(separator: ",")) }
            return result
        }
        work("phone.shutdown") { invocation, phones in
            try await phones.shutdown(try await device(invocation, phones).id)
        }
        work("phone.tap") { invocation, phones in
            try await phones.send(.tap(PhonePoint(x: try number(invocation, "x"), y: try number(invocation, "y"))),
                                  to: try await device(invocation, phones).id)
        }
        work("phone.swipe") { invocation, phones in
            let from = PhonePoint(x: try number(invocation, "fromX"), y: try number(invocation, "fromY"))
            let to = PhonePoint(x: try number(invocation, "toX"), y: try number(invocation, "toY"))
            let seconds = invocation["seconds"]?.stringValue.flatMap(Double.init) ?? 0.3
            try await phones.send(.swipe(from: from, to: to, seconds: seconds), to: try await device(invocation, phones).id)
        }
        work("phone.type") { invocation, phones in
            try await phones.send(.text(invocation["text"]?.stringValue ?? ""), to: try await device(invocation, phones).id)
        }
        work("phone.button") { invocation, phones in
            guard let name = invocation["button"]?.stringValue, let button = PhoneButton(rawValue: name) else {
                throw PhoneError.unreadable(what: "the button name")
            }
            try await phones.send(.button(button), to: try await device(invocation, phones).id)
        }
        answer("phone.ui") { invocation, phones in
            let device = try await device(invocation, phones)
            let tree = try await phones.accessibilityTree(device.id)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return ["device": .string(device.id.description), "elements": .int(tree.flattened.count),
                    "tree": .string(String(decoding: try encoder.encode(tree), as: UTF8.self))]
        }
        work("phone.appearance") { invocation, phones in
            guard let name = invocation["appearance"]?.stringValue, let appearance = PhoneAppearance(rawValue: name) else {
                throw PhoneError.unreadable(what: "the appearance")
            }
            try await phones.send(.appearance(appearance), to: try await device(invocation, phones).id)
        }
        work("phone.location") { invocation, phones in
            try await phones.send(.location(latitude: try number(invocation, "latitude"), longitude: try number(invocation, "longitude")),
                                  to: try await device(invocation, phones).id)
        }
        work("phone.locale") { invocation, phones in
            try await phones.send(.locale(invocation["locale"]?.stringValue ?? "en_US"), to: try await device(invocation, phones).id)
        }
        work("phone.install") { invocation, phones in
            guard let path = invocation["path"]?.stringValue else { throw PhoneError.unreadable(what: "the app path") }
            try await phones.send(.install(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)), to: try await device(invocation, phones).id)
        }
        work("phone.launch") { invocation, phones in
            guard let app = invocation["app"]?.stringValue, !app.isEmpty else { throw PhoneError.unreadable(what: "the app id") }
            try await phones.send(.launch(app), to: try await device(invocation, phones).id)
        }
        work("phone.rotate") { invocation, phones in
            try await phones.rotate(try await device(invocation, phones).id)
        }
        work("phone.logs") { invocation, phones in
            let line = try await phones.logShellLine(try await device(invocation, phones).id)
            guard let pane = context.paneController(invocation) else {
                throw PhoneError.unsupported(mode: .simulator, what: "logs without a window")
            }
            pane.newTerminalTab(typing: line + "\r")
        }
        bindShortcuts(into: registry, context: context)
        // The pane menu's New Simulator Pane opens the phone tab (one model for both names).
        registry.bind("palette.newSimulatorPane", run: { invocation in registry.perform("phone.show", invocation: invocation) })
        work("phone.recordStart") { invocation, phones in
            try await phones.startRecording(try await device(invocation, phones).id)
        }
        work("phone.recordStop") { invocation, phones in
            _ = try await phones.stopRecording(notes: invocation["notes"]?.stringValue ?? "")
        }
        work("phone.sendFeedback") { invocation, phones in
            _ = try await phones.sendFeedback(notes: invocation["notes"]?.stringValue ?? "")
        }
        work("phone.openURL") { invocation, phones in
            guard let text = invocation["url"]?.stringValue, let url = URL(string: text), url.scheme != nil else {
                throw PhoneError.unsupported(mode: .simulator, what: "a URL without a scheme")
            }
            try await phones.send(.openURL(url), to: try await device(invocation, phones).id)
        }
        work("phone.paste") { invocation, phones in
            try await phones.send(.pasteboard(invocation["text"]?.stringValue ?? ""), to: try await device(invocation, phones).id)
        }
    }

    /// The phone tab's keyboard shortcuts (`simulatorFocused`, published while a phone tab has the
    /// keyboard): each drives the phone the targeted or focused phone tab shows. The phone is read
    /// at once, so a run with no phone tab is refused before any work starts.
    private static func bindShortcuts(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        func shortcut(_ id: ActionID, _ body: @escaping @MainActor (PhoneDeviceID, PhoneService) async throws -> Void) {
            registry.bind(id, run: { invocation in
                guard let device = focusedPhone(invocation, context) else { return }
                let phones = services.phones
                // task-owner: the action run; a capturing caller (CLI, MCP) awaits it through the registry.
                registry.track(Task { @MainActor in
                    do {
                        try await body(device, phones)
                        return nil
                    } catch {
                        let reason = (error as? PhoneError)?.description ?? String(describing: error)
                        registry.refuse(reason)
                        return ActionWorkFailure(stringLiteral: reason)
                    }
                })
            })
        }
        shortcut("simulatorHome") { try await $1.send(.button(.home), to: $0) }
        shortcut("simulatorRotateLeft") { try await $1.rotate($0, .left) }
        shortcut("simulatorRotateRight") { try await $1.rotate($0, .right) }
        shortcut("simulatorToggleAppearance") { try await $1.toggleAppearance($0) }
        shortcut("simulatorToggleSoftwareKeyboard") { try await $1.send(.softwareKeyboard, to: $0) }
    }

    /// The phone the targeted or focused phone tab shows; refuses (and returns nil) without one.
    static func focusedPhone(_ invocation: ActionInvocation, _ context: AppActionContext) -> PhoneDeviceID? {
        guard let pane = context.scope(invocation).pane, case .page(let view)? = pane.currentContent, view.page == .phone,
              let device = (view.content as? PhoneTabView)?.route.flatMap(PhoneDeviceID.init) else {
            return context.refuse(MiscHandlerStrings.noPhoneTab)
        }
        return device
    }

    /// A required number argument (sent as a string so points may have fractions).
    static func number(_ invocation: ActionInvocation, _ name: String) throws -> Double {
        guard let text = invocation[name]?.stringValue ?? invocation[name]?.intValue.map(String.init), let value = Double(text), value.isFinite else {
            throw PhoneError.unreadable(what: name)
        }
        return value
    }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The phone named by `device` (`sim:<udid>`, `dev:<udid>`, or a name), else the default.
    @MainActor
    static func device(_ invocation: ActionInvocation, _ phones: PhoneService) async throws -> PhoneDevice {
        guard let text = invocation["device"]?.stringValue, !text.isEmpty else { return try await phones.defaultDevice() }
        if let id = PhoneDeviceID(text) { return try await phones.device(id) }
        if phones.devices.isEmpty { try await phones.reload() }
        guard let named = phones.devices.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) else {
            throw PhoneError.unknownDevice(text)
        }
        return named
    }
}
