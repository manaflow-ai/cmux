import Foundation

/// The page-side script contract for the browser "paste as plain text" focus tracker.
///
/// A live browser panel injects ``focusTrackingBootstrapScriptSource`` at document
/// start so the page continuously reports, via a `WKScriptMessageHandler` named
/// ``messageHandlerName``, whether the focused element can accept a plain-text
/// paste. The native side registers that same handler name and later evaluates
/// ``focusedTargetQueryScriptSource`` to synchronously read the current answer
/// before deciding whether to consume Cmd+Shift+V.
///
/// The handler name is stored state because the bootstrap script interpolates it,
/// so the JavaScript the page posts to and the native handler the app registers
/// are guaranteed to agree. The scripts are a byte-identical lift of the former
/// `CmuxWebView` static sources.
public struct BrowserPasteAsPlainTextFocusContract: Sendable, Equatable {
    /// The `WKScriptMessageHandler` name the page-side tracker posts focus updates to.
    ///
    /// The same name must be used when registering the native handler and when
    /// injecting ``focusTrackingBootstrapScriptSource`` so the two halves connect.
    public let messageHandlerName: String

    /// Creates a contract bound to a message-handler name.
    /// - Parameter messageHandlerName: The handler name shared by the page-side
    ///   tracker and the native `WKScriptMessageHandler`. Defaults to the cmux
    ///   browser's canonical `cmuxPasteAsPlainTextFocus` channel.
    public init(messageHandlerName: String = "cmuxPasteAsPlainTextFocus") {
        self.messageHandlerName = messageHandlerName
    }
}
