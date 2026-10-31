#if os(iOS)
import SwiftUI

/// Opens a file a session touched in the full-screen file preview (read from
/// the Mac over the link, inside the folders it shares). Unset where nothing
/// can read files: the Open File actions are hidden then.
public struct OpenFileAction: Sendable {
    let handler: (@MainActor @Sendable (String, Int?) -> Void)?

    public init(_ handler: (@MainActor @Sendable (_ path: String, _ line: Int?) -> Void)?) {
        self.handler = handler
    }

    public var isAvailable: Bool { handler != nil }

    @MainActor public func callAsFunction(_ path: String, line: Int? = nil) {
        handler?(path, line)
    }
}

extension EnvironmentValues {
    @Entry public var openSessionFile = OpenFileAction(nil)
}
#endif
