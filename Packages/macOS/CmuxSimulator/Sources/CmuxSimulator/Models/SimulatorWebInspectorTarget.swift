import Foundation

/// One Safari or `WKWebView` target exposed by a simulated application.
public struct SimulatorWebInspectorTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable identity for one application page within the attached Simulator.
    public let id: String
    /// Web Inspector's application identity used by WIR forwarding RPCs.
    public let applicationIdentifier: String
    /// Numeric Web Inspector page identity.
    public let pageIdentifier: UInt64
    /// Page title reported by WebKit.
    public let title: String
    /// Page URL reported by WebKit.
    public let url: String
    /// Raw WIR target type, such as `WIRTypeWebPage`.
    public let type: String
    /// Display name of the containing application.
    public let applicationName: String
    /// Bundle identifier of the containing application, when reported.
    public let bundleIdentifier: String?
    /// Whether another inspector connection currently owns the page.
    public let isInUse: Bool

    /// Creates one inspectable application page description.
    public init(
        id: String,
        applicationIdentifier: String,
        pageIdentifier: UInt64,
        title: String,
        url: String,
        type: String,
        applicationName: String,
        bundleIdentifier: String?,
        isInUse: Bool
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.pageIdentifier = pageIdentifier
        self.title = title
        self.url = url
        self.type = type
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.isInUse = isInUse
    }
}
