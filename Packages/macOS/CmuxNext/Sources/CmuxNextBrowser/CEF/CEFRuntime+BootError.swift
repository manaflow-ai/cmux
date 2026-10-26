import Foundation

extension CEFRuntime {
    /// Why Chromium did not start (``CEFRuntime/start(layout:environment:trigger:)``): the in-process
    /// load, the host attach or `CefInitialize`.
    enum BootError: Error, CustomStringConvertible {
        case notEmbedded
        case untrusted(String)
        case shim(CEFShimLibrary.LoadError)
        case framework(String)
        /// Host mode: no Chromium Host to attach to (the reason).
        case host(String)
        /// NSApp is not a CefAppProtocol NSApplication subclass.
        case application
        case initialize
        /// The app began to quit before a predicted start's framework read ran (``CEFFrameworkPrefetch``):
        /// nothing was mapped.
        case quit

        var description: String {
            switch self {
            case .notEmbedded: "runtime not embedded"
            case .untrusted(let item): "runtime signature: \(item)"
            case .shim(let error): "shim: \(error)"
            case .framework(let message), .host(let message): message
            case .application: "NSApp does not conform to CefAppProtocol"
            case .initialize: "CefInitialize failed"
            case .quit: "the app quit before the framework load"
            }
        }
    }
}
