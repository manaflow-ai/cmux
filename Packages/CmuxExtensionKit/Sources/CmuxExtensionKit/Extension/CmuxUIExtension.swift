import SwiftUI

/// Base protocol for CMUX extensions that render SwiftUI content.
@MainActor
public protocol CmuxUIExtension: CmuxExtension {
    /// SwiftUI content rendered inside the extension scene.
    associatedtype Body: View

    /// The view CMUX hosts for this extension.
    @ViewBuilder var body: Body { get }
}
