#if DEBUG
public import AppKit

/// DEBUG ONLY: Command Palette > Environment Secrets Playground (`debug.envSecretsPlayground`). Three
/// directions for the proposed Environment variables and secrets page of cmux Cloud (Ledger,
/// Sentences, Inspector), each in ten states (empty, `.env` paste review, saved secret, no host,
/// host approval, history, revoke now, scopes, an agent's secret request, and the `cmux secrets`
/// terminal frames), behind a live picker, on sample data only. The labels
/// are DEV-only English, as the other playgrounds' are. One window per owner: ``show(direction:state:dark:)``
/// opens it or raises the open one.
@MainActor
public final class EnvSecretsPlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.cloud.envSecretsPlayground")
    private let model = EnvSecretsPlaygroundModel()
    private var window: NSWindow?

    public override init() { super.init() }

    /// Shows the window on `direction` (1 to 3) and `state` (0 to 9), in the dark look when `dark` is
    /// true, the light look when false; a nil argument keeps what is shown.
    public func show(direction: Int? = nil, state: Int? = nil, dark: Bool? = nil) {
        if let direction, let pick = EnvSecretsPlaygroundModel.Direction(rawValue: direction) { model.direction = pick }
        if let state, let pick = EnvSecretsPlaygroundModel.Scene(rawValue: state) { model.scene = pick }
        if let dark { model.dark = dark }
        let window = window ?? makeWindow()
        self.window = window
        applyLook()
        (window.contentView as? EnvSecretsPlaygroundView)?.reload()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.identifier = Self.identifier
        window.title = "Environment Secrets Playground"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = EnvSecretsPlaygroundView(model: model, applyLook: { [weak self] in self?.applyLook() })
        window.center()
        return window
    }

    /// The Look picker (App, Light, Dark) sets the window's appearance; nil follows the app.
    private func applyLook() {
        window?.appearance = model.dark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
    }
}
#endif
