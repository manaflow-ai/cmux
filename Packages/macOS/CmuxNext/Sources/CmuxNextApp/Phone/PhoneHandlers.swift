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
        work("phone.screenshot") { invocation, phones in
            let device = try await device(invocation, phones)
            let file = invocation["path"]?.stringValue.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let saved = try await phones.screenshot(device.id, to: file)
            if invocation.origin == .user { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(saved.path, forType: .string) }
        }
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
