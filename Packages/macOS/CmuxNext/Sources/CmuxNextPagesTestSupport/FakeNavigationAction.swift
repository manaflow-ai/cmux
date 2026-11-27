public import AppKit
public import Foundation
import ObjectiveC
public import WebKit

/// A ``WKNavigationAction`` for a navigation delegate under test, with the source frame macOS 14's
/// WebKit gives for some navigations: none. Swift cannot return nil from the `sourceFrame`
/// override (WebKit declares it nonnull), so the subclass answers its getter through the
/// Objective-C runtime with nil, as the macOS 14 WebKit does.
@MainActor
public final class FakeNavigationAction: WKNavigationAction {
    private let fakeRequest: URLRequest
    private let fakeType: WKNavigationType

    /// A navigation to `url` of `type`, in the main frame (no target frame), with no source frame.
    public init(url: URL, type: WKNavigationType = .other) {
        fakeRequest = URLRequest(url: url)
        fakeType = type
        super.init()
        _ = Self.answerNilSourceFrame
    }

    override public var request: URLRequest { fakeRequest }
    override public var navigationType: WKNavigationType { fakeType }
    override public var targetFrame: WKFrameInfo? { nil }
    override public var modifierFlags: NSEvent.ModifierFlags { [] }
    override public var buttonNumber: Int { 0 }

    /// Installs the nil getter on this class once (a lazy constant, run by the first init).
    private static let answerNilSourceFrame: Void = {
        let selector = #selector(getter: WKNavigationAction.sourceFrame)
        let none: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        class_replaceMethod(FakeNavigationAction.self, selector, imp_implementationWithBlock(none), "@@:")
    }()
}
