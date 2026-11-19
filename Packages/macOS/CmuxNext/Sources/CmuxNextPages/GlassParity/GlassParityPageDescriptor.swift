public import Foundation

public extension PageDescriptor {
    /// The web half of the Liquid Glass Parity playground (webviews/src/pages/glass-parity; CmuxNextApp
    /// GlassParity/): the web UI's glass surfaces at boxes the App sends, over the App's backdrop.
    /// DEV and NIGHTLY only: the App opens it from `debug.glass_parity`.
    static let glassParity = PageDescriptor(id: "cmux.glass-parity", resource: "glass-parity",
                                            namespaces: ["cmux.glass_parity."])
}
