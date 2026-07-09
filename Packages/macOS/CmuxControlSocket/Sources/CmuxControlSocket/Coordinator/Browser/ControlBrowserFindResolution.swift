public import Foundation

/// The typed outcome of a `browser.find.*` element locator, returned by the
/// ``ControlBrowserQueryReading`` seam to ``ControlBrowserQueryWorker``.
///
/// Each case is the byte-faithful twin of one branch the legacy
/// `TerminalController.v2BrowserFindWithScript` /
/// `v2BrowserFindFirst` / `v2BrowserFindLast` / `v2BrowserFindNth` bodies took.
/// The worker shapes each case into the wire payload; the app conformer resolves
/// the browser panel, runs the finder JavaScript on the socket-worker lane,
/// decodes the result dictionary, allocates the element ref, and computes the
/// `workspace_ref`/`surface_ref` strings (those reach the god-owned handle
/// registry, which this package cannot touch).
public enum ControlBrowserFindResolution: Sendable, Equatable {
    /// The shared `v2BrowserWithPanelContext` head failed to resolve a browser
    /// surface. Carries the typed error the legacy head would have returned
    /// (`unavailable` / `not_found` / `invalid_params`).
    case panelUnavailable(ControlCallResult)

    /// `v2BrowserResolveSelector` returned `nil` for a supplied element-ref
    /// selector (the first/last/nth "Element reference not found" branch). The
    /// associated value is the raw selector the legacy body echoed under the
    /// `selector` data key.
    case selectorReferenceNotFound(rawSelector: String)

    /// `v2RunBrowserJavaScript` failed. The associated value is the JS error
    /// message the legacy body put under the `js_error` code.
    case jsError(message: String)

    /// The finder ran but matched nothing (the legacy `not_found` "Element not
    /// found" branch). `data` carries the exact data dictionary the legacy body
    /// attached: `nil` for the with-script family (which used its metadata, built
    /// by the worker), or `{selector}` / `{selector,index}` for first/last/nth
    /// (which used the resolved selector available only app-side).
    case notFound(data: [String: JSONValue]?)

    /// The finder matched an element. Carries the fields the legacy bodies read
    /// off the decoded result dictionary plus the resolved workspace/surface
    /// identity and refs and the allocated element ref.
    case found(ControlBrowserFoundElement)
}

/// A resolved `browser.find.*` element: the identity the worker needs to shape
/// the success payload, byte-faithful to the fields the legacy bodies emitted.
public struct ControlBrowserFoundElement: Sendable, Equatable {
    /// The resolved workspace id (`ctx.workspaceId`).
    public let workspaceID: UUID
    /// The `workspace_ref` string (`v2Ref(kind: .workspace, …)`), computed
    /// app-side against the god-owned handle registry.
    public let workspaceRef: String
    /// The resolved browser surface id (`ctx.surfaceId`).
    public let surfaceID: UUID
    /// The `surface_ref` string (`v2Ref(kind: .surface, …)`).
    public let surfaceRef: String
    /// The CSS selector the element ref was allocated against (the finder's
    /// returned selector for `find.*`/`find.last`/`find.nth`, or the requested
    /// selector for `find.first`).
    public let selector: String
    /// The allocated element ref string (`@eN`), used for both `element_ref` and
    /// `ref` payload keys.
    public let elementRef: String
    /// The element's tag, when the decoded result carried a `tag` string
    /// (`find.role`/`find.text`/… via `v2BrowserFindWithScript`). `nil` otherwise.
    public let tag: String?
    /// The element's text echo (see ``ControlBrowserFindResultText``).
    public let text: ControlBrowserFindResultText
    /// The matched index echo, only `find.nth` (emitted as `orNull`). `nil` for
    /// every other find action.
    public let index: ControlBrowserFindResultIndex?

    /// Creates a found-element value.
    public init(
        workspaceID: UUID,
        workspaceRef: String,
        surfaceID: UUID,
        surfaceRef: String,
        selector: String,
        elementRef: String,
        tag: String?,
        text: ControlBrowserFindResultText,
        index: ControlBrowserFindResultIndex?
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.selector = selector
        self.elementRef = elementRef
        self.tag = tag
        self.text = text
        self.index = index
    }
}

/// How a find result carries its echoed `text` field, preserving the two
/// distinct legacy shapes:
/// - the with-script family (`find.role`/`find.text`/…) added `payload["text"]`
///   ONLY when the decoded dict had a string (``ControlBrowserFindResultText/omitted``
///   means the key is absent from the payload);
/// - first/last/nth always wrote `payload["text"] = v2OrNull(dict["text"])`
///   (``ControlBrowserFindResultText/orNull(_:)``, JSON `null` when absent).
public enum ControlBrowserFindResultText: Sendable, Equatable {
    /// No `text` key in the payload (the with-script family's absent case).
    case omitted
    /// `payload["text"] = v2OrNull(value)` — the string, or JSON `null` when
    /// `nil` (first/last/nth).
    case orNull(String?)
    /// `payload["text"] = value` — a present string (the with-script family).
    case string(String)
}

/// How `find.nth` carries its echoed `index` field, preserving the legacy
/// `payload["index"] = v2OrNull(dict["index"])` shape (the index as a number, or
/// JSON `null`).
public enum ControlBrowserFindResultIndex: Sendable, Equatable {
    /// `payload["index"] = v2OrNull(value)` — the int, or JSON `null` when `nil`.
    case orNull(Int?)
}
