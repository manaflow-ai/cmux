import AppKit
public import CmuxMobileHost
import CmuxRemoteDesktop

/// The consent panel (c3-rd.md 8): every session asks the person at the Mac,
/// and so does every switch to control. A floating panel at the top center
/// of the active screen, Allow and Deny, no default button (Return does not
/// allow). The session cancels the request on its timeout (30 s: deny) or
/// when the phone goes away; the panel closes then.
public struct PanelRemoteDesktopConsent: RemoteDesktopConsent {
    private let deviceName: @Sendable (String) async -> String?

    /// - Parameter deviceName: the paired device's name for an install id (the trust store's).
    public init(deviceName: @escaping @Sendable (String) async -> String?) {
        self.deviceName = deviceName
    }

    public func request(_ request: RemoteDesktopConsentRequest) async -> Bool {
        let device = await deviceName(request.install) ?? MobileHostStrings.unknownDevice
        let title = MobileHostStrings.consentTitle(device: device, target: request.target.name, control: request.mode == .control)
        let prompt = await MainActor.run { ConsentPrompt(title: title) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { @MainActor in prompt.present(continuation) }
            }
        } onCancel: {
            Task { @MainActor in prompt.answer(false) }
        }
    }
}

/// One consent panel. Answered once: Allow, Deny, or a cancellation.
@MainActor
final class ConsentPrompt: NSObject {
    private let title: String
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answered = false

    init(title: String) {
        self.title = title
    }

    func present(_ continuation: CheckedContinuation<Bool, Never>) {
        guard !answered else {
            continuation.resume(returning: false)
            return
        }
        self.continuation = continuation
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = ""
        panel.contentView = content()
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.maxY - 170))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func answer(_ allowed: Bool) {
        guard !answered else { return }
        answered = true
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: allowed)
        continuation = nil
    }

    @objc private func allow() { answer(true) }
    @objc private func deny() { answer(false) }

    private func content() -> NSView {
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let message = NSTextField(wrappingLabelWithString: MobileHostStrings.consentMessage)
        message.textColor = .secondaryLabelColor
        let deny = NSButton(title: MobileHostStrings.deny, target: self, action: #selector(deny))
        let allow = NSButton(title: MobileHostStrings.allow, target: self, action: #selector(allow))
        // No default button: a stray Return must not allow.
        deny.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [deny, allow])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        return stack
    }
}
