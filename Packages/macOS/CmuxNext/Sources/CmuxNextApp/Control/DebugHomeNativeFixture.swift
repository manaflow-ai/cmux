#if DEBUG
import AppKit
import CmuxNextHome
import CmuxNextSettings

/// DEBUG ONLY: `debug.home_native_fixture.open` opens the native Home
/// transcript (`HomeNativeTranscriptView`) over the mock owner's fixture
/// data as an internal page tab of the active window, for screenshots
/// (`debug.window_snapshot`) and dogfood before the real Home wiring.
/// Compiled out of Release with this whole file.
extension InternalPageID {
    static let homeNativeFixture = InternalPageID(rawValue: "home-native-fixture")
}

@MainActor
final class DebugHomeNativeFixture: InternalPageProvider {
    private var fixtures: [String: HomeNativeFixture] = [:]
    /// The next page shows the attachment fixture (`{"attachments": true}`).
    var nextAttachments = false

    var page: InternalPageID { .homeNativeFixture }
    var title: String { HomeNativeFixture.title }
    var symbol: String { "bubble.left.and.bubble.right" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let fixture = HomeNativeFixture(attachments: nextAttachments)
        nextAttachments = false
        fixtures[key] = fixture
        return fixture.container
    }

    func tabClosed(_ key: String) {
        fixtures.removeValue(forKey: key)?.close()
    }

    /// `debug.home.attach`: the shown Home composer of the active window
    /// (the real Home tab or this fixture) takes the files by path.
    static func attach(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let paths = params["paths"]?.arrayValue?.compactMap(\.stringValue) ?? params["path"]?.stringValue.map { [$0] } ?? []
        guard let via = HomeAttachVia(rawValue: params["via"]?.stringValue ?? "drop") else {
            return .object(["error": .string("via must be drop, paste or pick")])
        }
        guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window) else {
            return .object(["error": .string("no Home conversation is shown")])
        }
        let result = view.attachFiles(paths: paths, via: via)
        return .object(["ok": .bool(result == .accepted), "result": .string(result.rawValue), "via": .string(via.rawValue)])
    }

    /// `debug.home.drive` {action: focus | type | send | tapback | scroll,
    /// text, dy}: drives the shown Home through its own entry points (the
    /// field's text system, Return's send, the tapback picker's react, the
    /// scroll view) for screenshots and recordings on a window that is
    /// never key.
    static func drive(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let view = HomeNativeTranscriptView.shown(in: services.windows.active?.window) else {
            return .object(["error": .string("no Home conversation is shown")])
        }
        let ok: Bool
        switch params["action"]?.stringValue ?? "" {
        case "focus": ok = view.window?.makeFirstResponder(view.primaryInput) ?? false
        case "type":
            guard let field = view.primaryInput as? NSTextView else { return .object(["error": .string("no field")]) }
            field.insertText(params["text"]?.stringValue ?? "", replacementRange: field.selectedRange())
            ok = true
        case "send": view.sendDraft(); ok = true
        case "tapback": ok = view.debugTapbackNewestIncoming()
        case "scroll": view.debugScroll(by: CGFloat(params["dy"]?.doubleValue ?? -400)); ok = true
        default: return .object(["error": .string("action must be focus, type, send, tapback or scroll")])
        }
        return .object(["ok": .bool(ok)])
    }

    static func open(services: AppServices, attachments: Bool = false) -> JSONValue {
        if services.pages.provider(.homeNativeFixture) == nil { services.pages.register(DebugHomeNativeFixture()) }
        (services.pages.provider(.homeNativeFixture) as? DebugHomeNativeFixture)?.nextAttachments = attachments
        let view = services.pages.show(.homeNativeFixture, in: services.windows.active, focus: true)
        return .object(["ok": .bool(view != nil), "page": .string(InternalPageID.homeNativeFixture.rawValue)])
    }
}
#endif
