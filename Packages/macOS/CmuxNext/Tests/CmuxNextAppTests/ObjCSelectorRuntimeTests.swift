import AppKit
import ObjectiveC
@testable import CmuxNextApp
import Testing

/// The "unrecognized selector sent to instance" crash class, checked in this macOS's Objective-C
/// runtime (scripts/cmux-next/check-objc-selectors.py checks the same class lexically, from a
/// probe table, on Linux).
///
/// Two nightly crashes on 2026-10-20 were messages to an object whose class had no
/// implementation: `super.draggingEnded(_:)` in a WKWebView subclass (WKWebView has none, yet
/// Swift compiles the call because NSView adopts NSDraggingDestination, whose methods are
/// optional), and Chromium sending `-cancelTerminate:` to NSApp, which is cmux's
/// `CmuxApplication`, not Chromium's `BrowserCrApplication`.
@MainActor @Suite
struct ObjCSelectorRuntimeTests {
    /// What Chromium's and CEF's Mac code send to NSApp beyond NSApplication's own API:
    /// `CrAppProtocol` (base/message_loop/message_pump_apple.mm reads `isHandlingSendEvent`),
    /// `CrAppControlProtocol` (base/apple/scoped_sending_event.mm sets it), `CefAppProtocol`
    /// (CEF checks NSApp conforms before `CefInitialize`), and `-cancelTerminate:`
    /// (chrome_browser_application_mac.mm, from a beforeunload dialog's Stay button).
    static let chromiumAppSelectors = ["isHandlingSendEvent", "setHandlingSendEvent:", "cancelTerminate:"]
    static let chromiumAppProtocols = ["CrAppProtocol", "CrAppControlProtocol", "CefAppProtocol"]

    /// cmux overrides of a framework protocol method that the framework superclass does not
    /// implement on some macOS, each read and found to make no `super` call (the override is the
    /// only implementation). An override that calls `super` there raises
    /// "unrecognized selector": remove the super call, then add the pair here.
    static let reviewedOverridesWithoutSuper: Set<String> = [
        // NSTextInputClient's optional placement: a constant answer, no super call.
        "CmuxNextAgentPane.AgentPaneWKWebView.preferredTextAccessoryPlacement",
        "CmuxNextPages.PageWKWebView.preferredTextAccessoryPlacement",
        // NSTextViewDelegate's menu hook (the field editor's delegate): builds its own menu, no super call.
        "CmuxNextBrowser.AddressField.textView:menu:forEvent:atIndex:",
        // NSDraggingDestination's optional end (NSView has none): no super call.
        "CmuxNextBrowser.CEFHostView.draggingEnded:",
        "CmuxNextHome.HomeNativeTranscriptView.draggingEnded:",
        // Forwards to its drop target, no super call.
        "CmuxNextHome.HomeSidebarSplitView.draggingEnded:",
        // Calls super only when WKWebView.instancesRespond(to: draggingEnded:) (WebKitDrag.ended).
        "CmuxNextPages.PageWKWebView.draggingEnded:",
        // NSStandardKeyBindingResponding's Escape: closes the modal, no super call.
        "CmuxNextUpdater.ShareCmuxMessageTextView.cancelOperation:",
    ]

    @Test func cmuxsApplicationAnswersWhatChromiumSendsToNSApp() throws {
        for name in Self.chromiumAppSelectors {
            #expect(CmuxApplication.instancesRespond(to: NSSelectorFromString(name)),
                    "CmuxApplication does not answer -\(name), which Chromium sends to NSApp")
        }
        for name in Self.chromiumAppProtocols {
            let proto = try #require(objc_getProtocol(name), "protocol \(name) is not registered")
            #expect(CmuxApplication.conforms(to: proto), "CmuxApplication does not conform to \(name)")
        }
    }

    /// Every cmux responder class (NSResponder, NSView, NSWindow, NSApplication subclasses) that
    /// implements a method of a protocol its framework ancestor adopts, where its superclass has no
    /// implementation on this macOS, is listed in ``reviewedOverridesWithoutSuper``. Swift lets
    /// such an override call `super` (the SDK says the superclass adopts the protocol), and that
    /// call raises at run time.
    @Test func everyOverrideTheSuperclassCannotAnswerIsReviewed() throws {
        let image = try #require(class_getImageName(CmuxApplication.self))
        // Names only, from cmux's own image: touching every class in the process (objc_copyClassList)
        // messages root classes such as JavaScriptCore's JSExport, which aborts.
        var count: UInt32 = 0
        let names = try #require(objc_copyClassNamesForImage(image, &count))
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        var protocolMethods: [ObjectIdentifier: Set<Selector>] = [:]
        var responders = 0
        var found: Set<String> = []
        for index in 0 ..< Int(count) {
            guard let cls = objc_lookUpClass(names[index]), Self.isResponder(cls),
                  let superclass = class_getSuperclass(cls),
                  let framework = Self.frameworkAncestor(of: cls, image: image) else { continue }
            responders += 1
            let declared = protocolMethods[ObjectIdentifier(framework)] ?? Self.protocolSelectors(adoptedBy: framework)
            protocolMethods[ObjectIdentifier(framework)] = declared
            for selector in Self.ownSelectors(of: cls) where declared.contains(selector) {
                if !class_respondsToSelector(superclass, selector) {
                    found.insert("\(NSStringFromClass(cls)).\(NSStringFromSelector(selector))")
                }
            }
        }
        #expect(responders > 50, "the walk found only \(responders) cmux responder classes")
        let unreviewed = found.subtracting(Self.reviewedOverridesWithoutSuper).sorted()
        #expect(unreviewed.isEmpty, """
            \(unreviewed.count) cmux override(s) of a protocol method the superclass does not implement on this \
            macOS. Check each has no super call, then add it to reviewedOverridesWithoutSuper:
            \(unreviewed.joined(separator: "\n"))
            """)
    }

    private static func isResponder(_ cls: AnyClass) -> Bool {
        var next: AnyClass? = class_getSuperclass(cls)
        while let current = next {
            if ObjectIdentifier(current) == ObjectIdentifier(NSResponder.self) { return true }
            next = class_getSuperclass(current)
        }
        return false
    }

    /// The nearest ancestor from outside cmux's image (AppKit, WebKit, ...).
    private static func frameworkAncestor(of cls: AnyClass, image: UnsafePointer<CChar>) -> AnyClass? {
        var next: AnyClass? = class_getSuperclass(cls)
        while let current = next {
            guard let name = class_getImageName(current), strcmp(name, image) == 0 else { return current }
            next = class_getSuperclass(current)
        }
        return nil
    }

    /// The instance methods (required and optional) of every protocol `cls` and its ancestors adopt.
    private static func protocolSelectors(adoptedBy cls: AnyClass) -> Set<Selector> {
        var selectors: Set<Selector> = []
        var visited: Set<String> = []
        func add(_ proto: Protocol) {
            guard visited.insert(String(cString: protocol_getName(proto))).inserted else { return }
            for required in [true, false] {
                var count: UInt32 = 0
                if let list = protocol_copyMethodDescriptionList(proto, required, true, &count) {
                    for index in 0 ..< Int(count) { if let name = list[index].name { selectors.insert(name) } }
                    free(list)
                }
            }
            var count: UInt32 = 0
            if let inherited = protocol_copyProtocolList(proto, &count) {
                for index in 0 ..< Int(count) { add(inherited[index]) }
            }
        }
        var next: AnyClass? = cls
        while let current = next {
            var count: UInt32 = 0
            if let list = class_copyProtocolList(current, &count) {
                for index in 0 ..< Int(count) { add(list[index]) }
            }
            next = class_getSuperclass(current)
        }
        return selectors
    }

    /// The instance methods `cls` itself implements (not inherited).
    private static func ownSelectors(of cls: AnyClass) -> [Selector] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [] }
        defer { free(list) }
        return (0 ..< Int(count)).map { method_getName(list[$0]) }
    }
}
