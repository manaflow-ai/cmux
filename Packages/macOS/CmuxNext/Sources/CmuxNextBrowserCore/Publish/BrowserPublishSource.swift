public import Foundation

/// The page's publish, as the App provides it to the popover.
public struct BrowserPublishSource {
    /// The name the field starts with.
    public var suggestedName: String
    /// The form for a typed name (nil: the suggested one) and an audience; nil when the rules cannot say.
    public var form: @MainActor (_ name: String?, _ team: Bool) -> BrowserPublishForm?
    /// Runs the publish.
    public var publish: @MainActor (_ name: String?, _ team: Bool) async -> BrowserPublishAnswer
    /// Shows the published app.
    public var open: @MainActor (URL) -> Void

    public init(suggestedName: String,
                form: @escaping @MainActor (String?, Bool) -> BrowserPublishForm?,
                publish: @escaping @MainActor (String?, Bool) async -> BrowserPublishAnswer,
                open: @escaping @MainActor (URL) -> Void) {
        self.suggestedName = suggestedName
        self.form = form
        self.publish = publish
        self.open = open
    }
}
