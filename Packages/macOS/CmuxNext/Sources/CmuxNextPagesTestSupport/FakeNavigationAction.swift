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
    private let fakeTarget: WKFrameInfo?

    /// A navigation to `url` of `type` into `targetFrame` (nil: the main frame of a new load),
    /// with no source frame.
    public init(url: URL, type: WKNavigationType = .other, targetFrame: WKFrameInfo? = nil) {
        fakeRequest = URLRequest(url: url)
        fakeType = type
        fakeTarget = targetFrame
        super.init()
        _ = Self.answerNilSourceFrame
    }

    override public var request: URLRequest { fakeRequest }
    override public var navigationType: WKNavigationType { fakeType }
    override public var targetFrame: WKFrameInfo? { fakeTarget }
    override public var modifierFlags: NSEvent.ModifierFlags { [] }
    override public var buttonNumber: Int { 0 }

    /// Installs the nil getter on this class once (a lazy constant, run by the first init).
    private static let answerNilSourceFrame: Void = {
        let selector = #selector(getter: WKNavigationAction.sourceFrame)
        let none: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
        class_replaceMethod(FakeNavigationAction.self, selector, imp_implementationWithBlock(none), "@@:")
    }()
}

/// A ``WKFrameInfo`` for a navigation delegate under test: a frame that shows `url`, the main
/// frame or a frame inside the page.
///
/// It is never freed. WebKit's `-[WKFrameInfo dealloc]` destroys the `API::FrameInfo` that WebKit
/// builds for its own frames; a test double made with `init` has none, and freeing it trapped
/// the test process (signal 5, fleet step 157b7689cf8089fabb69f4b7). A test makes a few.
@MainActor
public final class FakeFrameInfo: WKFrameInfo {
    private let fakeRequest: URLRequest
    private let fakeMain: Bool

    public init(url: URL, isMainFrame: Bool) {
        fakeRequest = URLRequest(url: url)
        fakeMain = isMainFrame
        super.init()
        _ = Unmanaged.passRetained(self)
    }

    override public var isMainFrame: Bool { fakeMain }
    override public var request: URLRequest { fakeRequest }
}
