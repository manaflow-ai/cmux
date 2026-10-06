public import Foundation

public extension PageDescriptor {
    /// The page's folder in this module's resource bundle (`Resources/pages/<resource>`), nil when
    /// it is not there (pages bundled by another module, such as the agent pane).
    var pagesBundleRoot: URL? { PageSchemeHandler.bundledRoot(for: self) }
}
