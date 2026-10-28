import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextFocus
import Foundation
import Testing

/// "dialog key handling unchanged", through the real main window (`ShellWindow`) with
/// the feature `overlayTopLayer` on: a dialog in the window's top layer keeps every key the key overlay
/// panel had. A key equivalent reaches only the dialog (an empty workspace's Return never makes a terminal
/// under it), a real Tab cycles inside it, and the focus model gets the keyboard back when it goes.
@MainActor @Suite(.serialized) struct OverlayTopLayerKeysTests {
    /// Counts the presses of a dialog's default button and the empty workspace's new-terminal requests.
    @MainActor
    final class Presses: NSObject {
        var dialog = 0
        var newTerminal = 0
        @objc func pressed(_ sender: Any?) { dialog += 1 }
    }

    @MainActor
    final class Shown {
        let services: AppServices
        let controller: WindowController
        let window: ShellWindow
        let host: WindowOverlayHost
        let presses = Presses()

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                            overrides: FeatureOverrides(environmentEnabled: ["overlayTopLayer"]))
            let store = services.machines.local.store
            let identity = try OverlayTopLayerKeysTests.connected()
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            var tree = DaemonTree(registryID: "s-local", workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1"),
            ])
            tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
            store.apply(snapshot: tree)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"top-layer-keys","workspace_key":"k1"}"#.utf8))
            let state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = ["k1"]
            controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
            window = try #require(controller.window as? ShellWindow)
            window.orderFrontRegardless()
            window.makeKey()
            host = WindowOverlayHost.host(for: window)
        }

        func close() {
            controller.teardown()
            window.close()
        }

        /// An empty workspace in the window's content, below the top layer: Return there makes a terminal.
        func addEmptyWorkspace() throws {
            let content = try #require(window.contentView)
            let empty = EmptyWorkspaceView(onNew: { [presses] in presses.newTerminal += 1 })
            empty.frame = content.bounds
            content.addSubview(empty, positioned: .below, relativeTo: nil)
        }

        /// A dialog with two fields and a default button (Return), presented as the App presents one.
        func presentDialog() -> (OverlayHandle, NSTextField, NSTextField) {
            let dialog = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 140))
            let first = NSTextField(frame: NSRect(x: 10, y: 100, width: 280, height: 22))
            let second = NSTextField(frame: NSRect(x: 10, y: 60, width: 280, height: 22))
            let ok = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
            ok.keyEquivalent = "\r"
            ok.target = presses
            ok.action = #selector(Presses.pressed(_:))
            for view in [first, second, ok] as [NSView] { dialog.addSubview(view) }
            let handle = host.present(dialog, options: OverlayOptions(kind: .dialog, isModal: true, dismissOnEscape: true,
                                                                      dimsContent: true, passesThroughClicks: false))
            return (handle, first, second)
        }

        func key(_ keyCode: UInt16, _ characters: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }

        /// The control with the keyboard (a text field for its field editor).
        var focused: NSResponder? {
            let responder = window.firstResponder
            if let editor = responder as? NSTextView, editor.isFieldEditor { return editor.delegate as? NSResponder }
            return responder
        }
    }

    static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func returnUnderADialogReachesOnlyTheDialog() throws {
        let shown = try Shown()
        defer { shown.close() }
        try shown.addEmptyWorkspace()
        let returnKey = try shown.key(36, "\r")

        let (handle, _, _) = shown.presentDialog()
        #expect(shown.host.isTopLayerInWindow, "the dialog is not in the window's top layer")
        #expect(shown.host.madePanel == nil)
        #expect(shown.window.overlayHasKeyboard, "the dialog did not take the window's keyboard")
        if let responder = shown.window.firstResponder {
            #expect(FocusResponderClassifier.classify(responder, in: shown.controller) == .textField,
                    "the focus model would take the keyboard back from the dialog")
        }
        #expect(shown.window.performKeyEquivalent(with: returnKey), "the dialog's default button did not take Return")
        #expect(shown.presses.dialog == 1)
        #expect(shown.presses.newTerminal == 0, "Return under the dialog made a terminal in the empty workspace")
        handle.dismiss()

        // The dialog went (it fades out where it was): its default button never takes Return again.
        #expect(!shown.window.overlayHasKeyboard)
        #expect(!shown.host.topLayer.performKeyEquivalent(with: returnKey))
        #expect(shown.presses.dialog == 1, "a fading dialog took the window's Return")
    }

    @Test func aRealTabCyclesInsideTheDialogAndTheKeyboardComesBack() throws {
        let shown = try Shown()
        defer { shown.close() }
        let (handle, first, second) = shown.presentDialog()
        #expect(shown.window.makeFirstResponder(first))
        #expect(shown.focused === first)

        // Tab through the window, as AppKit sends it: the field editor ends the edit and moves to the next key view.
        let tab = try shown.key(48, "\t")
        shown.window.sendEvent(tab)
        #expect(shown.focused === second, "Tab did not reach the dialog's next field")
        shown.window.sendEvent(tab)
        #expect(shown.focused === first, "Tab left the dialog")
        #expect(shown.window.overlayHasKeyboard)

        handle.dismiss()
        // The keyboard leaves the top layer, and the focus model owns it again (no dialog field holds it).
        #expect(!shown.window.overlayHasKeyboard)
        let after = shown.window.firstResponder as? NSView
        #expect(after.map { !$0.isDescendant(of: shown.host.topLayer) } ?? true, "the keyboard stayed in the dialog")
        #expect(FocusResponderClassifier.classify(shown.window.firstResponder, in: shown.controller) != .textField)
    }
}
