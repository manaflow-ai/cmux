import AppKit

extension AgentPaneView {
    /// Fork Conversation from the palette, the chat's right-click menu or its shortcut: the page
    /// forks the open chat through its latest finished turn (`chat.forkTo`) and asks the host to
    /// open the fork at `destination` (`chat.openTab`'s `placement`). A chat that cannot fork now
    /// (no turn yet, a harness without fork) says why in its transcript.
    ///
    /// The request is the user's gesture, as a native permission shortcut is.
    public func forkConversation(to destination: AgentForkDestination, offerDestinations: Bool = false) {
        AgentPanePersonInput.record(model.transport.gestures, sources: eventSources)
        if offerDestinations, let event = NSApp.currentEvent, event.type == .leftMouseUp, event.modifierFlags.contains(.option) {
            popUpForkMenu()
        } else {
            evaluateScript(Self.forkScript(destination))
        }
    }

    public func chooseForkDestination() {
        AgentPanePersonInput.record(model.transport.gestures, sources: eventSources)
        popUpForkMenu()
    }

    /// The page call the fork action runs; the destination is one of a closed set of
    /// raw values, so the script never carries outside text.
    static func forkScript(_ destination: AgentForkDestination) -> String {
        "window.cmuxAcpmuxActions?.['chat.forkTo']?.({ placement: '\(destination.rawValue)' });"
    }
}
