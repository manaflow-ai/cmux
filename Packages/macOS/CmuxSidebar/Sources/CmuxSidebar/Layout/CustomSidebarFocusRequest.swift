public import Foundation

/// A page's request to focus one workspace.
///
/// The wire form is exactly `{ v: 1, workspaceId: "<uuid>" }` and nothing else. Strictness is the
/// point: the bridge is the one thing a sidebar page can reach into the app with, so a request it
/// cannot fully account for is rejected rather than interpreted. An extra key means the page is
/// speaking a protocol this build does not implement, and guessing at the overlap is how a future
/// field silently becomes optional.
public struct CustomSidebarFocusRequest: Equatable, Sendable {
    /// The workspace the page wants focused.
    public let workspaceID: UUID

    /// Parses a message body, returning `nil` for anything that is not exactly the expected shape.
    ///
    /// - Parameter messageBody: The raw `postMessage` body as WebKit delivered it.
    public init?(messageBody: Any) {
        guard let object = messageBody as? [String: Any], object.count == 2 else { return nil }
        // Swift bridges `true` and `1` to the same NSNumber value, so the boolean is excluded by
        // CoreFoundation type rather than by comparison: `{ v: true }` is a page speaking some other
        // protocol, not this one.
        guard let rawVersion = object["v"],
              CFGetTypeID(rawVersion as CFTypeRef) != CFBooleanGetTypeID(),
              let version = rawVersion as? Int,
              version == CustomSidebarFocusStatus.protocolVersion
        else { return nil }
        guard let rawID = object["workspaceId"] as? String,
              let workspaceID = UUID(uuidString: rawID)
        else { return nil }
        self.workspaceID = workspaceID
    }
}
