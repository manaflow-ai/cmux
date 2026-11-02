public import CmuxNextDaemon

/// The app server link's launcher, and its route as launched for `cloud.machines`' `link_route`: `legacy`,
/// `link`, or the Native-first launcher's (``CloudNativeFirstLauncher/route``).
@MainActor
public struct CloudAppServerLink {
    /// Nil for the legacy link (no app server link).
    public let launcher: (any CloudLinkLaunching)?
    public let route: @MainActor () -> String

    /// The launcher of an `appServer` link source: this Mac's `cmux link` (`link`), or with `choice` `.native`
    /// (`CMUX_NEXT_CLOUD_NATIVE_LINK=1`, #28947) the Native device route `native()` makes, with `link` as its
    /// fallback when Native does not start (`onFallback` says why). `native` runs only for that choice.
    public init(appServer: Bool, link: (any CloudLinkLaunching)?,
                choice: CloudNativeFirstLauncher.Choice = CloudNativeFirstLauncher.choice(),
                native: () -> (any CloudLinkLaunching)?, onFallback: @escaping (any Error) -> Void) {
        if !appServer {
            (launcher, route) = (nil, { "legacy" })
        } else if choice == .link {
            (launcher, route) = (link, { "link" })
        } else if let native = native() {
            let first = CloudNativeFirstLauncher(native: native, link: link, onFallback: onFallback)
            (launcher, route) = (first, { first.route })
        } else {
            (launcher, route) = (link, { "link (native asked; no Native route holder for this app)" })
        }
    }
}
