import Foundation

/// Engine-neutral counterpart to `WKUserContentController`.
///
/// Holds the set of injected user scripts and the registry of script
/// message handlers the host wants exposed to page JavaScript. Backends
/// translate this into engine-specific machinery at view construction
/// time.
public final class CmuxUserContentController: @unchecked Sendable {
    public private(set) var userScripts: [CmuxUserScript] = []
    public private(set) var messageHandlers: [String: any CmuxScriptMessageHandler] = [:]

    public init() {}

    public func addUserScript(_ script: CmuxUserScript) {
        userScripts.append(script)
    }

    public func removeAllUserScripts() {
        userScripts.removeAll()
    }

    /// Register a handler for `window.webkit.messageHandlers.<name>` (or
    /// the Chromium equivalent the backend wires up). Re-registering an
    /// existing name replaces the previous handler.
    public func add(_ handler: any CmuxScriptMessageHandler, name: String) {
        messageHandlers[name] = handler
    }

    public func removeScriptMessageHandler(forName name: String) {
        messageHandlers[name] = nil
    }
}

public struct CmuxUserScript: Sendable {
    public enum InjectionTime: Sendable {
        case atDocumentStart
        case atDocumentEnd
    }

    public let source: String
    public let injectionTime: InjectionTime
    public let forMainFrameOnly: Bool

    public init(
        source: String,
        injectionTime: InjectionTime,
        forMainFrameOnly: Bool
    ) {
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
    }
}

public protocol CmuxScriptMessageHandler: AnyObject, Sendable {
    func didReceive(_ message: CmuxScriptMessage)
}

public struct CmuxScriptMessage: Sendable {
    public let name: String
    public let body: CmuxScriptMessageBody
    public let frameURL: URL?
    public let isMainFrame: Bool

    public init(
        name: String,
        body: CmuxScriptMessageBody,
        frameURL: URL?,
        isMainFrame: Bool
    ) {
        self.name = name
        self.body = body
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
    }
}

/// Type-erased JS-message body. Engine backends marshal native
/// `NSNumber`/`NSString`/`NSDictionary`/`NSArray` (WebKit) or Mojo
/// values (Chromium) into this.
public enum CmuxScriptMessageBody: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([CmuxScriptMessageBody])
    case dictionary([String: CmuxScriptMessageBody])
    case data(Data)
}
