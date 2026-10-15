import Foundation

/// A script injected into every document a page loads.
public struct BrowserPageUserScript: Equatable, Hashable, Sendable {
    /// When the script runs in a document.
    public enum InjectionTime: Equatable, Hashable, Sendable {
        /// Before any page script runs.
        case documentStart
        /// After the document finished parsing.
        case documentEnd
    }

    /// The JavaScript source.
    public var source: String
    /// When the script runs.
    public var injectionTime: InjectionTime
    /// `true` to run only in the main frame.
    public var isMainFrameOnly: Bool
    /// The world the script runs in.
    public var world: BrowserPageScriptWorld

    /// Creates a user script.
    /// - Parameters:
    ///   - source: The JavaScript source.
    ///   - injectionTime: When the script runs.
    ///   - isMainFrameOnly: `true` to skip subframes; defaults to `true`.
    ///   - world: The world the script runs in; defaults to the page world.
    public init(
        source: String,
        injectionTime: InjectionTime,
        isMainFrameOnly: Bool = true,
        world: BrowserPageScriptWorld = .page
    ) {
        self.source = source
        self.injectionTime = injectionTime
        self.isMainFrameOnly = isMainFrameOnly
        self.world = world
    }
}
